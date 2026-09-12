import sqlite3
import tempfile
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from reset_nfc_test_state import reset


class ResetNfcTestStateTest(unittest.TestCase):
    def setUp(self):
        self.file = tempfile.NamedTemporaryFile(suffix='.sqlite', delete=False)
        self.file.close()
        db = sqlite3.connect(self.file.name)
        db.executescript('''
          CREATE TABLE reservations(id INTEGER PRIMARY KEY,reservation_number TEXT);
          CREATE TABLE guests(id INTEGER PRIMARY KEY,reservation_id INTEGER,wristband_code TEXT);
          CREATE TABLE wristband_credentials(id INTEGER PRIMARY KEY,reservation_id INTEGER,guest_id INTEGER,guest_name TEXT,status TEXT,wristband_code TEXT);
        ''')
        db.execute("INSERT INTO reservations VALUES (1,'RES-20080')")
        db.execute("INSERT INTO guests VALUES (1,1,'OLD')")
        db.execute("INSERT INTO guests VALUES (2,1,'REAL')")
        db.execute("INSERT INTO wristband_credentials VALUES (1,1,1,'Teste','uncertain','OLD')")
        db.execute("INSERT INTO wristband_credentials VALUES (2,1,2,'Real','encoded','REAL')")
        db.commit(); db.close()

    def tearDown(self): Path(self.file.name).unlink(missing_ok=True)

    def test_only_non_confirmed_states_are_removed(self):
        self.assertEqual(reset(self.file.name, 'RES-20080', 'RESET RES-20080'), 0)
        db = sqlite3.connect(self.file.name)
        self.assertIsNone(db.execute('SELECT wristband_code FROM guests WHERE id=1').fetchone()[0])
        self.assertEqual(db.execute('SELECT COUNT(*) FROM wristband_credentials WHERE guest_id=1').fetchone()[0], 0)
        self.assertEqual(db.execute("SELECT status FROM wristband_credentials WHERE guest_id=2").fetchone()[0], 'encoded')
        self.assertEqual(db.execute('SELECT wristband_code FROM guests WHERE id=2').fetchone()[0], 'REAL')
        db.close()

    def test_wrong_confirmation_does_nothing(self):
        self.assertEqual(reset(self.file.name, 'RES-20080', 'RESET OTHER'), 2)
        db = sqlite3.connect(self.file.name)
        self.assertEqual(db.execute('SELECT COUNT(*) FROM wristband_credentials WHERE guest_id=1').fetchone()[0], 1)
        db.close()
