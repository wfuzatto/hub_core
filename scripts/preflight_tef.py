#!/usr/bin/env python3
import json, os, sys, urllib.request

enabled=str(os.getenv('TEF_ENABLED','false')).lower() in ('1','true','yes','on')
if not enabled:
    print('TEF................. DISABLED (safe default)')
    raise SystemExit(0)
url=os.getenv('TEF_AGENT_URL','').rstrip('/'); token=os.getenv('TEF_AGENT_TOKEN',''); terminal=os.getenv('TEF_DEFAULT_TERMINAL_ID','PPC930-FOOD-01')
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
