import contextlib
import io
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from configure_nfc import apply_update, parse_dotenv, persist_configuration, safe_summary, updated_text


class ConfigureNfcTest(unittest.TestCase):
    def values(self, secret='NEW$CHALLENGE6'):
        return {
            'HOTEL_CARD_PROVIDER': 'bis_api',
            'BIS_API_URL': 'http://192.0.2.20:8765',
            'BIS_API_WRITE_CONFIRMATION': secret,
            'BIS_API_TIMEOUT_MS': '15000',
            'HOTEL_ACCESS_CHECKIN_TIME': '14:00',
            'HOTEL_ACCESS_CHECKOUT_TIME': '12:00',
            'HOTEL_ACCESS_UTC_OFFSET': '-03:00'
        }

    def test_replaces_old_value_and_keeps_other_variables(self):
        old = "PAYMENT_API_KEY='payment'\nBIS_API_WRITE_CONFIRMATION='OLDVALUE'\nBIS_API_WRITE_CONFIRMATION='DUPLICATE'\nFACE_SCANNER_API_KEY='face'\n"
        new = updated_text(old, self.values())
        parsed = parse_dotenv(new)
        self.assertEqual(parsed['BIS_API_WRITE_CONFIRMATION'], 'NEW$CHALLENGE6')
        self.assertNotIn('OLDVALUE', new)
        self.assertNotIn('DUPLICATE', new)
        self.assertEqual(parsed['PAYMENT_API_KEY'], 'payment')
        self.assertEqual(parsed['FACE_SCANNER_API_KEY'], 'face')

    def test_special_characters_and_single_quoted_input(self):
        for secret in ['a$b#c!d', "a'b\\c", 'a"b$#c']:
            content = updated_text("BIS_API_WRITE_CONFIRMATION='old'\n", {'BIS_API_WRITE_CONFIRMATION': secret})
            self.assertEqual(parse_dotenv(content)['BIS_API_WRITE_CONFIRMATION'], secret)
        self.assertEqual(parse_dotenv("X='literal $dollar #hash'\n")['X'], 'literal $dollar #hash')

    def test_backup_permissions_and_exact_post_write_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); target = root / '.env'; target.write_text("PAYMENT_API_KEY='same'\nBIS_API_WRITE_CONFIRMATION='OLD'\n", encoding='utf-8'); os.chmod(target, 0o600)
            backup = persist_configuration(target, self.values(), root / 'backups')
            self.assertEqual(parse_dotenv(target.read_text())['BIS_API_WRITE_CONFIRMATION'], 'NEW$CHALLENGE6')
            self.assertEqual(stat.S_IMODE(target.stat().st_mode) & 0o600, 0o600)
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode) & 0o600, 0o600)
            self.assertEqual(parse_dotenv(backup.read_text())['BIS_API_WRITE_CONFIRMATION'], 'OLD')

    def test_rollback_on_persistence_divergence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); target = root / '.env'; original = "KEEP='yes'\nBIS_API_WRITE_CONFIRMATION='OLD'\n"; target.write_text(original, encoding='utf-8'); os.chmod(target, 0o600)
            with patch('configure_nfc.os.replace', side_effect=OSError('simulated persistence failure')):
                with self.assertRaises(Exception): persist_configuration(target, self.values(), root / 'backups')
            self.assertEqual(target.read_text(), original)

    def test_output_never_contains_secret(self):
        secret = 'PRIVATE-TEST-123'
        output = io.StringIO()
        with contextlib.redirect_stdout(output): safe_summary('http://192.0.2.20:8765', secret)
        self.assertNotIn(secret, output.getvalue())

    def test_apply_runs_only_as_separate_validated_step_and_never_prints_secret(self):
        secret = 'PRIVATE-TEST-123'
        fake = type('Result', (), {'stdout': 'provider=bis_api\n', 'stderr': '', 'returncode': 0})()
        with patch('configure_nfc.subprocess.run', return_value=fake) as run:
            output = io.StringIO()
            with contextlib.redirect_stdout(output): apply_update('/tmp/hub_core', secret)
        run.assert_called_once()
        self.assertNotIn(secret, output.getvalue())
        self.assertEqual(run.call_args.args[0], ['bash', 'scripts/update_module.sh', 'totem_autoatendimento'])


if __name__ == '__main__':
    unittest.main()
