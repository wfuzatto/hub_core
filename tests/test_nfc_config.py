import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from validate_nfc import validate
from configure_nfc import updated_text


class NfcConfigTest(unittest.TestCase):
    def env(self):
        return dict(HOTEL_CARD_PROVIDER='bis_api', BIS_API_URL='http://192.0.2.20:8765',
                    BIS_API_WRITE_CONFIRMATION='TEST$SECRET', HOTEL_ACCESS_CHECKIN_TIME='14:00',
                    HOTEL_ACCESS_CHECKOUT_TIME='12:00', HOTEL_ACCESS_UTC_OFFSET='-03:00')

    def test_missing_and_invalid_configuration(self):
        self.assertEqual(validate(self.env()), [])
        for key in self.env():
            env = self.env(); env[key] = ''
            self.assertTrue(validate(env), key)
        for url in ['foo', 'http://', 'ftp://example.com', 'http://127.0.0.1:8765', 'http://user:pass@example.com', 'http://host:99999']:
            env = self.env(); env['BIS_API_URL'] = url
            self.assertTrue(validate(env), url)
        for time in ['24:00', '12:70', '3pm']:
            env = self.env(); env['HOTEL_ACCESS_CHECKIN_TIME'] = time
            self.assertTrue(validate(env))

    def test_explicit_mock_only(self):
        self.assertEqual(validate(dict(HOTEL_CARD_PROVIDER='mock')), [])
        self.assertTrue(validate({}))

    def test_preserves_other_integrations_and_quotes_secret_literally(self):
        original = '# payment\nPAYMENT_API_KEY=unchanged\nFACE_SCANNER_API_KEY=unchanged\nHOTEL_CARD_PROVIDER=mock\n'
        result = updated_text(original, self.env())
        self.assertIn('PAYMENT_API_KEY=unchanged', result)
        self.assertIn('FACE_SCANNER_API_KEY=unchanged', result)
        self.assertIn("BIS_API_WRITE_CONFIRMATION='TEST$SECRET'", result)
        self.assertEqual(result.count('HOTEL_CARD_PROVIDER='), 1)
        self.assertEqual(updated_text(result, self.env()), result)


if __name__ == '__main__':
    unittest.main()
