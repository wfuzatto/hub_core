#!/usr/bin/env python3
"""Configure real NFC in .env; prompt for the write challenge without echoing it."""
import argparse
import datetime
import getpass
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
from validate_nfc import validate


def updated_text(original, values):
    # Single-quoted dotenv values are literal, so '$' in a challenge isn't interpolated.
    for value in values.values():
        if any(c in value for c in "\r\n'\\"):
            raise ValueError('Valores não podem conter quebras de linha, aspas simples ou barra invertida.')
    lines = original.splitlines()
    for key, value in values.items():
        lines = [line for line in lines if not re.match(r'^\s*(?:export\s+)?' + key + r'\s*=', line)]
        lines.append(key + "='" + value + "'")
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='http://IP_WINDOWS:8765')
    parser.add_argument('--checkin', default='14:00')
    parser.add_argument('--checkout', default='12:00')
    parser.add_argument('--offset', default='-03:00')
    parser.add_argument('--confirmation-stdin', action='store_true', help='Read challenge from a secure pipe instead of a terminal prompt')
    args = parser.parse_args()
    secret = sys.stdin.readline().rstrip('\r\n') if args.confirmation_stdin else getpass.getpass('BisApi.RequireWriteChallenge (não é o HPASS): ')
    values = dict(HOTEL_CARD_PROVIDER='bis_api', BIS_API_URL=args.url, BIS_API_WRITE_CONFIRMATION=secret,
                  BIS_API_TIMEOUT_MS='15000', HOTEL_ACCESS_CHECKIN_TIME=args.checkin,
                  HOTEL_ACCESS_CHECKOUT_TIME=args.checkout, HOTEL_ACCESS_UTC_OFFSET=args.offset)
    errors = validate(values)
    if errors:
        raise ValueError('; '.join(errors))
    root = Path(__file__).resolve().parents[1]
    target = root / '.env'
    original = target.read_text(encoding='utf-8')
    content = updated_text(original, values)
    backup_dir = root / 'backups'
    backup_dir.mkdir(mode=0o700, exist_ok=True)
    backup = backup_dir / ('.env.before-nfc-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    old_umask = os.umask(0o077)
    try:
        shutil.copyfile(target, backup)
        os.chmod(backup, 0o600)
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=root, prefix='.env.nfc-', delete=False) as tmp:
            tmp.write(content)
        os.replace(tmp.name, target)
        os.chmod(target, 0o600)
    finally:
        os.umask(old_umask)
    print('NFC real configurado. Segredo preservado somente no .env. Backup em backups/.env.before-nfc-*')
    print('Aplicar: bash scripts/update_module.sh totem_autoatendimento')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Do not let parse/IO failures print secret-bearing values.
        print('ERRO: configuração NFC não aplicada. Verifique URL, horários, challenge e permissões do .env.', file=sys.stderr)
        sys.exit(1)
