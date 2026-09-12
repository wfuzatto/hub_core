import os, tempfile, unittest
from datetime import datetime, timezone, timedelta
os.environ['TEF_DRIVER']='mock'
from tef_agent import Store, TefError

class TefAgentTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.store=Store(os.path.join(self.tmp.name,'tef.sqlite3'))
        self.store.ensure_terminal('PPC930-TEST')
    def tearDown(self): self.tmp.cleanup()
    def payload(self,payment='p1',scenario='approve'):
        return {'payment_id':payment,'terminal_id':'PPC930-TEST','amount_cents':100,'currency':'BRL','method':'debit_card','installments':1,'metadata':{'scenario':scenario}}
    def age(self,txid,seconds):
        created=(datetime.now(timezone.utc)-timedelta(seconds=seconds)).isoformat()
        with self.store.conn() as c:c.execute('UPDATE transactions SET created_at=? WHERE id=?',(created,txid))
    def test_idempotency(self):
        a=self.store.create(self.payload()); b=self.store.create(self.payload()); self.assertEqual(a['id'],b['id'])
    def test_idempotency_conflict(self):
        self.store.create(self.payload()); p=self.payload(); p['amount_cents']=200
        with self.assertRaises(TefError) as cm:self.store.create(p)
        self.assertEqual(cm.exception.code,'IDEMPOTENCY_CONFLICT')
    def test_terminal_busy(self):
        self.store.create(self.payload('p1'))
        with self.assertRaises(TefError) as cm:self.store.create(self.payload('p2'))
        self.assertEqual(cm.exception.code,'TEF_TERMINAL_BUSY')
    def test_mock_reaches_authorized(self):
        tx=self.store.create(self.payload()); self.age(tx['id'],5)
        self.assertEqual(self.store.get(tx['id'])['status'],'AUTHORIZED')
    def test_mock_decline(self):
        tx=self.store.create(self.payload(scenario='decline')); self.age(tx['id'],5)
        self.assertEqual(self.store.get(tx['id'])['status'],'DECLINED')
    def test_confirm_requires_authorized(self):
        tx=self.store.create(self.payload())
        with self.assertRaises(TefError):self.store.confirm(tx['id'])
    def test_authorized_then_confirm(self):
        tx=self.store.create(self.payload()); self.store.transition(tx['id'],'AUTHORIZED','test')
        confirmed=self.store.confirm(tx['id']); self.assertEqual(confirmed['status'],'APPROVED')
        again=self.store.confirm(tx['id']); self.assertEqual(again['status'],'APPROVED')
    def test_cancel_releases_terminal(self):
        tx=self.store.create(self.payload()); self.store.cancel(tx['id']); other=self.store.create(self.payload('p2')); self.assertTrue(other['id'])
    def test_raw_card_rejected(self):
        p=self.payload(); p['metadata']['card_number']='4111111111111111'
        with self.assertRaises(TefError) as cm:self.store.create(p)
        self.assertEqual(cm.exception.code,'RAW_CARD_DATA_FORBIDDEN')
    def test_restart_recovery(self):
        tx=self.store.create(self.payload()); Store(self.store.path); recovered=Store(self.store.path).get(tx['id'],advance=False)
        self.assertEqual(recovered['status'],'RECOVERY_REQUIRED')
    def test_authorized_restart_stays_authorized(self):
        tx=self.store.create(self.payload()); self.store.transition(tx['id'],'AUTHORIZED','test'); restarted=Store(self.store.path)
        self.assertEqual(restarted.get(tx['id'],advance=False)['status'],'AUTHORIZED'); self.assertTrue(restarted.list_recovery())

if __name__=='__main__': unittest.main(verbosity=2)
