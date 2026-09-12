#!/usr/bin/env python3
import json, os, time, urllib.request
base=os.getenv('TEF_AGENT_URL','http://127.0.0.1:8766').rstrip('/'); token=os.getenv('TEF_AGENT_TOKEN','change_me_before_lan')
def req(path,method='GET',body=None):
    data=json.dumps(body).encode() if body is not None else None
    r=urllib.request.Request(base+path,data=data,method=method,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(r,timeout=5) as x:return json.load(x)
print('health',json.load(urllib.request.urlopen(base+'/health')))
print('device',req('/v1/device'))
payment='SMOKE-'+str(int(time.time()))
tx=req('/v1/transactions','POST',{'payment_id':payment,'terminal_id':os.getenv('TEF_DEFAULT_TERMINAL_ID','PPC930-FOOD-01'),'amount_cents':100,'currency':'BRL','method':'debit_card','installments':1,'metadata':{'scenario':'approve'}})
print('created',tx)
for _ in range(12):
    time.sleep(.5); tx=req('/v1/transactions/'+tx['id']); print('status',tx['status'])
    if tx['status'] in ('AUTHORIZED','DECLINED','ERROR'):break
if tx['status']!='AUTHORIZED':raise SystemExit('mock did not authorize')
tx=req('/v1/transactions/'+tx['id']+'/confirm','POST',{}); print('confirmed',tx)
assert tx['status']=='APPROVED'
print('OK')
