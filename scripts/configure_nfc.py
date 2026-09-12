#!/usr/bin/env python3
"""Configure real NFC in .env; prompt for the write challenge without echoing it."""
import argparse
import datetime
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from validate_nfc import validate


KEY_RE = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=')


def dotenv_value(raw):
    value = raw.strip()
    if value.startswith("'"):
        end = value.find("'", 1)
        if end < 0 or value[end + 1:].strip() and not value[end + 1:].lstrip().startswith('#'):
            raise ValueError('Valor dotenv com aspas simples inválido.')
        return value[1:end]
    if value.startswith('"'):
        escaped = False
        out = []
        for index, char in enumerate(value[1:], 1):
            if escaped:
                out.append({'n': '\n', 'r': '\r', 't': '\t'}.get(char, char))
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                tail = value[index + 1:].strip()
                if tail and not tail.startswith('#'):
                    raise ValueError('Valor dotenv com aspas duplas inválido.')
                return ''.join(out)
            else:
                out.append(char)
        raise ValueError('Valor dotenv com aspas duplas inválido.')
    return value.split('#', 1)[0].rstrip()


def parse_dotenv(text):
    parsed = {}
    for line in text.splitlines():
        match = KEY_RE.match(line)
        if match:
            parsed[match.group(1)] = dotenv_value(line[match.end():])
    return parsed


def quote_dotenv(value):
    # Single quotes are easiest to audit. Double quotes support apostrophes and
    # backslashes while remaining valid to Docker Compose's dotenv parser.
    if "'" not in value and '\n' not in value and '\r' not in value and '\\' not in value:
        return "'" + value + "'"
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'


def updated_text(original, values):
    for value in values.values():
        if not isinstance(value, str) or any(c in value for c in '\r\n'):
            raise ValueError('Valores não podem conter quebras de linha.')
    lines = original.splitlines()
    first_index = {}
    kept = []
    for line in lines:
        match = KEY_RE.match(line)
        key = match.group(1) if match else None
        if key in values:
            first_index.setdefault(key, len(kept))
            continue
        kept.append(line)
    additions = [(key + '=' + quote_dotenv(value)) for key, value in values.items()]
    insert_at = min(first_index.values()) if first_index else len(kept)
    kept[insert_at:insert_at] = additions
    return '\n'.join(kept) + '\n'


def secret_summary(secret):
    return 'length=' + str(len(secret)) + ' sha256_prefix=' + hashlib.sha256(secret.encode()).hexdigest()[:16]


def safe_summary(url, secret, applied=False):
    print('NFC REAL CONFIGURADO')
    print('Provider: bis_api')
    print('BisApi: ' + url)
    print('Challenge: configurado (' + secret_summary(secret) + ')')
    print('Totem: ' + ('atualizado' if applied else 'configurado'))


def apply_update(root, secret):
    result = subprocess.run(['bash', 'scripts/update_module.sh', 'totem_autoatendimento'], cwd=root, text=True, capture_output=True)
    combined = (result.stdout or '') + (result.stderr or '')
    if secret and secret in combined:
        raise RuntimeError('O update exibiu o challenge; operação abortada.')
    if result.returncode:
        raise RuntimeError('Atualização do Totem falhou; o .env persistido foi mantido.')
    print(combined, end='')


def persist_configuration(target, values, backup_dir):
    target = Path(target)
    original = target.read_text(encoding='utf-8')
    content = updated_text(original, values)
    backup_dir = Path(backup_dir)
    backup_dir.mkdir(mode=0o700, exist_ok=True)
    backup = backup_dir / ('.env.before-nfc-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    old_umask = os.umask(0o077)
    try:
        shutil.copyfile(target, backup)
        os.chmod(backup, 0o600)
        temp_name = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=target.parent, prefix='.env.nfc-', delete=False) as tmp:
                temp_name = tmp.name
                tmp.write(content)
                tmp.flush()
                os.fsync(tmp.fileno())
            os.replace(temp_name, target)
        finally:
            if temp_name and os.path.exists(temp_name): os.unlink(temp_name)
        os.chmod(target, 0o600)
        persisted = parse_dotenv(target.read_text(encoding='utf-8'))
        if any(persisted.get(key) != value for key, value in values.items()):
            raise ValueError('A configuração NFC persistida diverge do valor validado.')
        if (target.stat().st_mode & 0o600) != 0o600 or (backup.stat().st_mode & 0o600) != 0o600:
            raise ValueError('Permissões inseguras no .env ou backup.')
    except Exception:
        shutil.copyfile(backup, target)
        os.chmod(target, 0o600)
        raise
    finally:
        os.umask(old_umask)
    return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='http://IP_WINDOWS:8765')
    parser.add_argument('--checkin', default='14:00')
    parser.add_argument('--checkout', default='12:00')
    parser.add_argument('--offset', default='-03:00')
    parser.add_argument('--confirmation-stdin', action='store_true', help='Read challenge from a secure pipe instead of a terminal prompt')
    parser.add_argument('--apply', action='store_true', help='Run the isolated Totem update after persistence and validation')
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
    backup = persist_configuration(target, values, root / 'backups')
    if args.apply:
        apply_update(root, secret)
        safe_summary(args.url, secret, applied=True)
        return
    safe_summary(args.url, secret, applied=False)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Do not let parse/IO failures print secret-bearing values.
        print('ERRO: configuração NFC não aplicada. Verifique URL, horários, challenge, persistência e permissões do .env.', file=sys.stderr)
        sys.exit(1)
