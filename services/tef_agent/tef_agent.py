#!/usr/bin/env python3
"""Local TEF edge agent. Standard-library only; no real card data is ever accepted."""
from __future__ import annotations
import json, os, platform, re, secrets, sqlite3, subprocess, time, uuid
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

TERMINAL = {"APPROVED","DECLINED","CANCELED","ERROR"}
INTERACTIVE = {"WAITING_TERMINAL","WAITING_CARD","CARD_READ","WAITING_PIN","PROCESSING"}
FORBIDDEN = {"pan","cardnumber","card_number","cvv","cvc","cvv2","cvc2","pin","track1","track2","magstripe","rawcard","raw_card"}


def now(): return datetime.now(timezone.utc).isoformat()
def env_bool(name, default=False): return str(os.getenv(name, str(default))).lower() in {"1","true","yes","on"}
def safe_json(v): return json.dumps(v, ensure_ascii=False, separators=(",",":"))

def scan_forbidden(value, path="$"):
    if isinstance(value, dict):
        for k, v in value.items():
            key = re.sub(r"\s+", "", str(k).lower())
            if key in FORBIDDEN: return f"{path}.{k}"
            found = scan_forbidden(v, f"{path}.{k}")
            if found: return found
    elif isinstance(value, list):
        for i, v in enumerate(value):
            found = scan_forbidden(v, f"{path}[{i}]")
            if found: return found
    return None

class TefError(Exception):
    def __init__(self, code, message, status=400):
        super().__init__(message); self.code=code; self.status=status

class Store:
    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.path=path; self._init(); self.recover_startup()
    def conn(self):
        c=sqlite3.connect(self.path, timeout=10, isolation_level=None)
        c.row_factory=sqlite3.Row; c.execute("PRAGMA foreign_keys=ON"); c.execute("PRAGMA busy_timeout=10000"); return c
    def _init(self):
        with self.conn() as c:
            c.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS terminals(
              terminal_id TEXT PRIMARY KEY, model TEXT, device TEXT, status TEXT NOT NULL DEFAULT 'READY',
              active_transaction_id TEXT, lease_until TEXT, heartbeat_at TEXT, updated_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS transactions(
              id TEXT PRIMARY KEY, payment_id TEXT NOT NULL UNIQUE, terminal_id TEXT NOT NULL,
              amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, method TEXT NOT NULL, installments INTEGER NOT NULL,
              scenario TEXT NOT NULL DEFAULT 'approve', status TEXT NOT NULL, external_id TEXT,
              authorization_code TEXT, nsu TEXT, network TEXT, brand TEXT, receipt TEXT,
              request_hash TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              authorized_at TEXT, confirmed_at TEXT, canceled_at TEXT);
            CREATE TABLE IF NOT EXISTS transaction_events(
              id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_id TEXT NOT NULL, event_type TEXT NOT NULL,
              from_status TEXT, to_status TEXT, payload_json TEXT, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS recovery_journal(
              id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_id TEXT NOT NULL, reason TEXT NOT NULL,
              resolved INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, resolved_at TEXT);
            """)
    def recover_startup(self):
        with self.conn() as c:
            c.execute("BEGIN IMMEDIATE")
            rows=c.execute("SELECT id,status,terminal_id FROM transactions WHERE status IN ('WAITING_TERMINAL','WAITING_CARD','CARD_READ','WAITING_PIN','PROCESSING')").fetchall()
            for r in rows:
                c.execute("UPDATE transactions SET status='RECOVERY_REQUIRED',updated_at=? WHERE id=?",(now(),r['id']))
                c.execute("INSERT INTO transaction_events(transaction_id,event_type,from_status,to_status,payload_json,created_at) VALUES(?,?,?,?,?,?)",
                          (r['id'],'startup.recovery',r['status'],'RECOVERY_REQUIRED','{}',now()))
                c.execute("INSERT INTO recovery_journal(transaction_id,reason,created_at) VALUES(?,?,?)",(r['id'],'agent_restarted_during_interactive_session',now()))
            auth=c.execute("SELECT id FROM transactions WHERE status='AUTHORIZED'").fetchall()
            for r in auth:
                exists=c.execute("SELECT 1 FROM recovery_journal WHERE transaction_id=? AND resolved=0",(r['id'],)).fetchone()
                if not exists: c.execute("INSERT INTO recovery_journal(transaction_id,reason,created_at) VALUES(?,?,?)",(r['id'],'authorized_waiting_confirmation_after_restart',now()))
            c.execute("COMMIT")
    def ensure_terminal(self, terminal_id, model=None, device=None):
        with self.conn() as c:
            c.execute("INSERT INTO terminals(terminal_id,model,device,status,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(terminal_id) DO UPDATE SET model=COALESCE(excluded.model,model),device=COALESCE(excluded.device,device),updated_at=excluded.updated_at",
                      (terminal_id,model,device,'READY',now()))
    def _hash(self, data):
        import hashlib
        stable={k:data.get(k) for k in ('payment_id','terminal_id','amount_cents','currency','method','installments')}
        return hashlib.sha256(safe_json(stable).encode()).hexdigest()
    def event(self,c,tid,event,frm,to,payload=None):
        c.execute("INSERT INTO transaction_events(transaction_id,event_type,from_status,to_status,payload_json,created_at) VALUES(?,?,?,?,?,?)",
                  (tid,event,frm,to,safe_json(payload or {}),now()))
    def create(self,data):
        forbidden=scan_forbidden(data)
        if forbidden: raise TefError('RAW_CARD_DATA_FORBIDDEN',f'Raw card data is forbidden ({forbidden})',422)
        required=('payment_id','terminal_id','amount_cents','method')
        if any(not data.get(k) for k in required): raise TefError('INVALID_REQUEST','payment_id, terminal_id, amount_cents and method are required',422)
        amount=int(data['amount_cents']); installments=int(data.get('installments',1))
        if amount<=0 or installments<1: raise TefError('INVALID_REQUEST','Invalid amount/installments',422)
        method=str(data['method']).lower()
        if method not in ('debit_card','credit_card'): raise TefError('INVALID_METHOD','TEF supports debit_card/credit_card',422)
        req_hash=self._hash({**data,'amount_cents':amount,'installments':installments,'currency':data.get('currency','BRL')})
        scenario=str((data.get('metadata') or {}).get('scenario') or 'approve').lower()
        if scenario not in {'approve','decline','timeout','communication_error','disconnect','authorization_then_crash'}: scenario='approve'
        txid=str(uuid.uuid4()); ts=now(); lease=(datetime.now(timezone.utc)+timedelta(minutes=3)).isoformat()
        with self.conn() as c:
            c.execute("BEGIN IMMEDIATE")
            existing=c.execute("SELECT * FROM transactions WHERE payment_id=?",(str(data['payment_id']),)).fetchone()
            if existing:
                c.execute("COMMIT")
                if existing['request_hash'] != req_hash: raise TefError('IDEMPOTENCY_CONFLICT','payment_id reused with different payload',409)
                return dict(existing)
            terminal=c.execute("SELECT * FROM terminals WHERE terminal_id=?",(str(data['terminal_id']),)).fetchone()
            if not terminal:
                c.execute("INSERT INTO terminals(terminal_id,status,updated_at) VALUES(?,?,?)",(str(data['terminal_id']),'READY',ts))
                terminal=c.execute("SELECT * FROM terminals WHERE terminal_id=?",(str(data['terminal_id']),)).fetchone()
            if terminal['active_transaction_id']:
                active=c.execute("SELECT status FROM transactions WHERE id=?",(terminal['active_transaction_id'],)).fetchone()
                if active and active['status'] not in TERMINAL:
                    c.execute("ROLLBACK")
                    raise TefError('TEF_TERMINAL_BUSY','Terminal is busy',409)
            c.execute("INSERT INTO transactions(id,payment_id,terminal_id,amount_cents,currency,method,installments,scenario,status,request_hash,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                      (txid,str(data['payment_id']),str(data['terminal_id']),amount,str(data.get('currency','BRL')),method,installments,scenario,'WAITING_CARD',req_hash,ts,ts))
            c.execute("UPDATE terminals SET status='BUSY',active_transaction_id=?,lease_until=?,heartbeat_at=?,updated_at=? WHERE terminal_id=?",(txid,lease,ts,ts,str(data['terminal_id'])))
            self.event(c,txid,'transaction.created',None,'WAITING_CARD',{'scenario':scenario})
            c.execute("COMMIT")
        return self.get(txid, advance=False)
    def _release(self,c,row):
        c.execute("UPDATE terminals SET status='READY',active_transaction_id=NULL,lease_until=NULL,heartbeat_at=?,updated_at=? WHERE terminal_id=? AND active_transaction_id=?",(now(),now(),row['terminal_id'],row['id']))
    def transition(self,txid,to,event,payload=None):
        with self.conn() as c:
            c.execute("BEGIN IMMEDIATE"); row=c.execute("SELECT * FROM transactions WHERE id=?",(txid,)).fetchone()
            if not row:
                c.execute("ROLLBACK")
                raise TefError('TRANSACTION_NOT_FOUND','Transaction not found',404)
            frm=row['status']; fields=["status=?","updated_at=?"]; args=[to,now()]
            if to=='AUTHORIZED': fields += ["authorized_at=?","authorization_code=?","nsu=?","network=?","brand=?"]; args += [now(),f"AUTH{secrets.randbelow(999999):06d}",f"NSU{secrets.randbelow(999999999):09d}",'MOCK','MOCKCARD']
            if to=='APPROVED': fields += ["confirmed_at=?"]; args += [now()]
            if to=='CANCELED': fields += ["canceled_at=?"]; args += [now()]
            args.append(txid); c.execute(f"UPDATE transactions SET {','.join(fields)} WHERE id=?",args)
            self.event(c,txid,event,frm,to,payload)
            fresh=c.execute("SELECT * FROM transactions WHERE id=?",(txid,)).fetchone()
            if to in TERMINAL:
                self._release(c,fresh)
                c.execute("UPDATE recovery_journal SET resolved=1,resolved_at=? WHERE transaction_id=? AND resolved=0",(now(),txid))
            c.execute("COMMIT"); return dict(fresh)
    def advance_mock(self,row):
        if row['status'] not in INTERACTIVE: return row
        age=time.time()-datetime.fromisoformat(row['created_at']).timestamp(); scenario=row['scenario']
        if scenario=='timeout' and age>=5: return self.transition(row['id'],'ERROR','mock.timeout')
        if scenario in {'communication_error','disconnect'} and age>=2: return self.transition(row['id'],'ERROR',f'mock.{scenario}')
        if age>=4: return self.transition(row['id'],'DECLINED' if scenario=='decline' else 'AUTHORIZED','mock.authorization')
        if age>=3 and row['status']!='PROCESSING': return self.transition(row['id'],'PROCESSING','mock.progress')
        if age>=2 and row['status'] not in {'WAITING_PIN','PROCESSING'}: return self.transition(row['id'],'WAITING_PIN','mock.progress')
        if age>=1 and row['status']=='WAITING_CARD': return self.transition(row['id'],'CARD_READ','mock.progress')
        return row
    def get(self,txid,advance=True):
        with self.conn() as c: row=c.execute("SELECT * FROM transactions WHERE id=?",(txid,)).fetchone()
        if not row: raise TefError('TRANSACTION_NOT_FOUND','Transaction not found',404)
        row=dict(row)
        return self.advance_mock(row) if advance and os.getenv('TEF_DRIVER','mock')=='mock' else row
    def confirm(self,txid):
        row=self.get(txid)
        if row['status']=='APPROVED': return row
        if row['status']!='AUTHORIZED': raise TefError('INVALID_TRANSACTION_STATE',f"Cannot confirm {row['status']}",409)
        return self.transition(txid,'APPROVED','transaction.confirmed')
    def cancel(self,txid):
        row=self.get(txid)
        if row['status']=='CANCELED': return row
        if row['status']=='APPROVED': raise TefError('INVALID_TRANSACTION_STATE','Approved transaction requires refund',409)
        return self.transition(txid,'CANCELED','transaction.canceled')
    def refund(self,txid,body):
        row=self.get(txid)
        if row['status']!='APPROVED': raise TefError('INVALID_TRANSACTION_STATE','Only approved transaction can be refunded',409)
        amount=int(body.get('amount_cents') or row['amount_cents'])
        if amount<=0 or amount>row['amount_cents']: raise TefError('INVALID_REFUND_AMOUNT','Invalid refund amount',422)
        return {**row,'status':'APPROVED','refund_id':str(body.get('refund_id') or uuid.uuid4()),'refund_amount_cents':amount}
    def list_terminals(self):
        with self.conn() as c: return [dict(r) for r in c.execute("SELECT * FROM terminals ORDER BY terminal_id")]
    def list_recovery(self):
        with self.conn() as c: return [dict(r) for r in c.execute("SELECT r.*,t.payment_id,t.terminal_id,t.status FROM recovery_journal r JOIN transactions t ON t.id=r.transaction_id WHERE r.resolved=0 ORDER BY r.id")]
    def events(self,txid):
        with self.conn() as c: return [dict(r) for r in c.execute("SELECT * FROM transaction_events WHERE transaction_id=? ORDER BY id",(txid,))]
    def recent(self,limit=20):
        with self.conn() as c: return [dict(r) for r in c.execute("SELECT id,payment_id,terminal_id,amount_cents,method,status,created_at,updated_at FROM transactions ORDER BY created_at DESC LIMIT ?",(limit,))]

class Hardware:
    @staticmethod
    def _run(cmd):
        try: return subprocess.check_output(cmd,stderr=subprocess.STDOUT,text=True,timeout=4,encoding='utf-8',errors='replace')
        except Exception: return ''
    @classmethod
    def discover(cls):
        system=platform.system().lower(); found=[]
        if system=='windows':
            ps="Get-PnpDevice -PresentOnly | Where-Object {$_.FriendlyName -match 'Gertec|PPC|PIN.?Pad|USB Serial|COM'} | Select-Object Status,Class,FriendlyName,InstanceId | ConvertTo-Json -Compress"
            raw=cls._run(['powershell','-NoProfile','-Command',ps])
            try:
                obj=json.loads(raw) if raw else []; found=obj if isinstance(obj,list) else ([obj] if obj else [])
            except Exception: pass
        elif system=='linux':
            raw=cls._run(['lsusb'])
            for line in raw.splitlines():
                if re.search(r'gertec|ppc|pin.?pad',line,re.I): found.append({'description':line.strip()})
            for pattern in ('/dev/ttyACM','/dev/ttyUSB'):
                for i in range(16):
                    p=f'{pattern}{i}'
                    if Path(p).exists(): found.append({'device':p})
        text=safe_json(found).lower(); detected=bool(found and any(x in text for x in ('gertec','ppc','pinpad','pin pad')))
        return {'detected':detected,'manufacturer':'Gertec' if 'gertec' in text else None,'model':'PPC930' if 'ppc930' in text else None,
                'transport':'USB' if found else None,'devices':found,'os':platform.platform(),'tef_driver_ready':os.getenv('TEF_DRIVER','mock')!='sitef' or bool(os.getenv('SITEF_LIBRARY'))}

class SitefDriver:
    @staticmethod
    def status():
        lib=os.getenv('SITEF_LIBRARY','')
        return {'configured':bool(lib),'implemented':False,'library':lib or None,'real_payments_enabled':False,
                'error':'SITEF_DRIVER_NOT_IMPLEMENTED' if lib else 'SITEF_SDK_NOT_INSTALLED'}

class App:
    def __init__(self):
        self.host=os.getenv('TEF_AGENT_HOST','127.0.0.1'); self.port=int(os.getenv('TEF_AGENT_PORT','8766'))
        self.token=os.getenv('TEF_AGENT_TOKEN','change_me_before_lan'); self.driver=os.getenv('TEF_DRIVER','mock').lower()
        self.default_terminal=os.getenv('TEF_DEFAULT_TERMINAL_ID','PPC930-FOOD-01')
        self.store=Store(os.getenv('TEF_DB_PATH',str(Path(__file__).with_name('data')/'tef_agent.sqlite3')))
        hw=Hardware.discover(); device=(hw.get('devices') or [{}])[0].get('device') if isinstance((hw.get('devices') or [{}])[0],dict) else None
        self.store.ensure_terminal(self.default_terminal,hw.get('model'),device)
    def health(self): return {'status':'ok','service':'tef_agent','driver':self.driver,'real_payments_enabled':False if self.driver=='sitef' else env_bool('TEF_REAL_PAYMENTS_ENABLED',False),'time':now()}
    def status(self): return {'service':'tef_agent','driver':self.driver,'terminal_id':self.default_terminal,'device':Hardware.discover(),'sitef':SitefDriver.status(),'recovery_pending':len(self.store.list_recovery())}

APP=App()

def public_tx(row):
    if not row: return row
    allowed=('id','payment_id','terminal_id','amount_cents','currency','method','installments','status','external_id','authorization_code','nsu','network','brand','receipt','created_at','updated_at','authorized_at','confirmed_at','canceled_at')
    out={k:row.get(k) for k in allowed if k in row}
    if out.get('status') in INTERACTIVE|{'AUTHORIZED','RECOVERY_REQUIRED'}: out['next_action']={'type':'TERMINAL','state':out['status'],'terminal_id':out.get('terminal_id')}
    return out

class Handler(BaseHTTPRequestHandler):
    server_version='ValeTefAgent/0.1'
    def log_message(self,fmt,*args): print(safe_json({'ts':now(),'event':'http','message':fmt%args}))
    def sendj(self,status,obj):
        raw=json.dumps(obj,ensure_ascii=False).encode(); self.send_response(status); self.send_header('content-type','application/json; charset=utf-8'); self.send_header('content-length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def body(self):
        length=int(self.headers.get('content-length','0') or 0); raw=self.rfile.read(length) if length else b'{}'
        try: data=json.loads(raw or b'{}')
        except Exception: raise TefError('INVALID_JSON','Invalid JSON',400)
        forbidden=scan_forbidden(data)
        if forbidden: raise TefError('RAW_CARD_DATA_FORBIDDEN',f'Raw card data is forbidden ({forbidden})',422)
        return data
    def auth(self):
        supplied=self.headers.get('authorization','').removeprefix('Bearer ').strip() or self.headers.get('x-tef-agent-key','')
        if not secrets.compare_digest(str(supplied),str(APP.token)): raise TefError('UNAUTHORIZED','Unauthorized',401)
    def dashboard(self):
        rows=APP.store.recent(); status=APP.status(); body=f"""<!doctype html><meta charset=utf-8><title>TEF Agent</title><style>body{{font:16px system-ui;max-width:1100px;margin:40px auto;padding:0 20px}}table{{border-collapse:collapse;width:100%}}td,th{{padding:8px;border-bottom:1px solid #ddd;text-align:left}}code{{background:#eee;padding:2px 5px}}</style><h1>TEF Agent</h1><p>Status: <b>ONLINE</b> · Driver: <b>{APP.driver.upper()}</b> · Real payments: <b>{'ENABLED' if APP.health()['real_payments_enabled'] else 'DISABLED'}</b></p><p>Terminal: <code>{APP.default_terminal}</code> · PPC930 detected: <b>{'YES' if status['device']['detected'] else 'NO/UNKNOWN'}</b> · Recovery: {status['recovery_pending']}</p><p>SiTef SDK: <b>{'CONFIGURED' if status['sitef']['configured'] else 'NOT INSTALLED'}</b> · Driver native: <b>{'READY' if status['sitef']['implemented'] else 'NOT IMPLEMENTED'}</b></p><h2>Recent transactions</h2><table><tr><th>ID</th><th>Payment</th><th>Terminal</th><th>Amount</th><th>Method</th><th>Status</th></tr>{''.join(f"<tr><td>{r['id'][:8]}</td><td>{r['payment_id']}</td><td>{r['terminal_id']}</td><td>R$ {r['amount_cents']/100:.2f}</td><td>{r['method']}</td><td>{r['status']}</td></tr>" for r in rows)}</table>""".encode()
        self.send_response(200); self.send_header('content-type','text/html; charset=utf-8'); self.send_header('content-length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def route(self,method):
        p=urlparse(self.path).path
        if p=='/' and method=='GET': return self.dashboard()
        if p=='/health' and method=='GET': return self.sendj(200,APP.health())
        self.auth()
        if p=='/v1/device' and method=='GET': return self.sendj(200,Hardware.discover())
        if p=='/v1/status' and method=='GET': return self.sendj(200,APP.status())
        if p=='/v1/terminals' and method=='GET': return self.sendj(200,{'terminals':APP.store.list_terminals()})
        if p=='/v1/recovery/pending' and method=='GET': return self.sendj(200,{'transactions':APP.store.list_recovery()})
        if p=='/v1/transactions' and method=='POST':
            if APP.driver=='sitef':
                if not env_bool('TEF_REAL_PAYMENTS_ENABLED'): raise TefError('TEF_REAL_PAYMENTS_DISABLED','Real TEF payments are disabled',503)
                raise TefError('SITEF_DRIVER_NOT_IMPLEMENTED','Official SiTef native driver is not implemented yet',501)
            if APP.driver!='mock': raise TefError('TEF_DRIVER_NOT_SUPPORTED',f'Unsupported TEF driver: {APP.driver}',503)
            return self.sendj(202,public_tx(APP.store.create(self.body())))
        m=re.fullmatch(r'/v1/transactions/([^/]+)(?:/(confirm|cancel|refund))?',p)
        if m:
            txid,action=m.group(1),m.group(2)
            if method=='GET' and not action: return self.sendj(200,public_tx(APP.store.get(txid)))
            if method=='POST' and action=='confirm': return self.sendj(200,public_tx(APP.store.confirm(txid)))
            if method=='POST' and action=='cancel': return self.sendj(200,public_tx(APP.store.cancel(txid)))
            if method=='POST' and action=='refund': return self.sendj(200,public_tx(APP.store.refund(txid,self.body())))
        m=re.fullmatch(r'/v1/events/([^/]+)',p)
        if m and method=='GET': return self.sendj(200,{'events':APP.store.events(m.group(1))})
        raise TefError('NOT_FOUND','Not found',404)
    def do_GET(self):
        try:self.route('GET')
        except TefError as e:self.sendj(e.status,{'error':e.code,'message':str(e)})
        except Exception as e: print(safe_json({'ts':now(),'event':'error','error':type(e).__name__})); self.sendj(500,{'error':'INTERNAL_ERROR'})
    def do_POST(self):
        try:self.route('POST')
        except TefError as e:self.sendj(e.status,{'error':e.code,'message':str(e)})
        except Exception as e: print(safe_json({'ts':now(),'event':'error','error':type(e).__name__})); self.sendj(500,{'error':'INTERNAL_ERROR'})

if __name__=='__main__':
    print(safe_json({'event':'startup','host':APP.host,'port':APP.port,'driver':APP.driver,'terminal':APP.default_terminal,'real_payments_enabled':APP.health()['real_payments_enabled']}))
    ThreadingHTTPServer((APP.host,APP.port),Handler).serve_forever()
