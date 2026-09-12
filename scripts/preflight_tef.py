#!/usr/bin/env python3
import json, os, sys, urllib.request
from pathlib import Path


def load_env_file(path='.env'):
    values={}
    p=Path(path)
    if not p.exists(): return values
    for raw in p.read_text(encoding='utf-8',errors='replace').splitlines():
        line=raw.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        key,value=line.split('=',1)
        key=key.strip(); value=value.strip()
        if len(value)>=2 and value[0]==value[-1] and value[0] in ('"',"'"): value=value[1:-1]
        values[key]=value
    return values

file_env=load_env_file()
def cfg(name, default=''):
    return os.getenv(name, file_env.get(name, default))

enabled=str(cfg('TEF_ENABLED','false')).lower() in ('1','true','yes','on')
if not enabled:
    print('TEF................. DISABLED (safe default)')
    raise SystemExit(0)
url=cfg('TEF_AGENT_URL','').rstrip('/'); token=cfg('TEF_AGENT_TOKEN',''); terminal=cfg('TEF_DEFAULT_TERMINAL_ID','PPC930-FOOD-01')
if not url or not token:
    print('TEF preflight: TEF_AGENT_URL/TEF_AGENT_TOKEN ausentes',file=sys.stderr); raise SystemExit(2)
def get(path,auth=False):
    headers={'Authorization':'Bearer '+token} if auth else {}
    with urllib.request.urlopen(urllib.request.Request(url+path,headers=headers),timeout=5) as r:return json.load(r)
try:
    health=get('/health'); status=get('/v1/status',True); device=get('/v1/device',True); terms=get('/v1/terminals',True)
except Exception as e:
    print('TEF preflight falhou:',type(e).__name__,str(e),file=sys.stderr); raise SystemExit(3)
ids={x.get('terminal_id') for x in terms.get('terminals',[])}
print('TEF Agent............', 'OK' if health.get('status')=='ok' else 'ERROR')
print('Driver...............', status.get('driver','unknown'))
print('PPC930 USB...........', 'OK' if device.get('detected') else 'NOT DETECTED/UNKNOWN')
print('Terminal.............', terminal, 'OK' if terminal in ids else 'NOT REGISTERED')
print('SiTef SDK............', 'CONFIGURED' if status.get('sitef',{}).get('configured') else 'NOT INSTALLED')
print('Real payments........', 'ENABLED' if status.get('sitef',{}).get('real_payments_enabled') else 'DISABLED')
if terminal not in ids: raise SystemExit(4)
