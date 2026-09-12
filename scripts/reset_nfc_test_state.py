#!/usr/bin/env python3
"""Remove only non-confirmed NFC attempts for one explicitly named reservation."""
import argparse
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


STATUSES = ('uncertain', 'failed', 'encoding')


def database_path(explicit=None):
    if explicit:
        return Path(explicit)
    candidates = [Path(os.environ['TOTEM_DB_PATH'])] if os.environ.get('TOTEM_DB_PATH') else []
    candidates += [Path('data/totem.sqlite'), Path('modules/totem_autoatendimento/data/totem.sqlite')]
    try:
        volume = subprocess.run(['docker', 'volume', 'inspect', 'hub_core_totem_data', '--format', '{{.Mountpoint}}'], text=True, capture_output=True, check=True).stdout.strip()
        if volume: candidates.append(Path(volume) / 'totem.sqlite')
    except (OSError, subprocess.CalledProcessError):
        pass
    for path in candidates:
        if path.exists(): return path
    raise FileNotFoundError('Banco do Totem não localizado. Use TOTEM_DB_PATH ou --db.')


def reset(path, reservation_number, confirm):
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    try:
        reservation = connection.execute('SELECT id, reservation_number FROM reservations WHERE reservation_number=?', (reservation_number,)).fetchone()
        if not reservation: raise ValueError('Reserva não encontrada.')
        rows = connection.execute("SELECT id,guest_id,guest_name,status,wristband_code FROM wristband_credentials WHERE reservation_id=? AND status IN ('uncertain','failed','encoding')", (reservation['id'],)).fetchall()
        print('Reserva: ' + reservation['reservation_number'])
        print('Tentativas removíveis: ' + str(len(rows)))
        for row in rows: print(f"guest_id={row['guest_id']} status={row['status']} code_present={bool(row['wristband_code'])}")
        if not rows: return 0
        if confirm != 'RESET ' + reservation_number:
            print('Operação cancelada. Digite exatamente: RESET ' + reservation_number)
            return 2
        with connection:
            for row in rows:
                encoded = connection.execute("SELECT 1 FROM wristband_credentials WHERE guest_id=? AND status='encoded'", (row['guest_id'],)).fetchone()
                if encoded: continue
                connection.execute('UPDATE guests SET wristband_code=NULL WHERE id=? AND reservation_id=?', (row['guest_id'], reservation['id']))
                connection.execute('DELETE FROM wristband_credentials WHERE id=? AND status IN (\'uncertain\',\'failed\',\'encoding\')', (row['id'],))
        print('Estado de teste removido. Nenhuma gravação NFC foi executada.')
        return 0
    finally: connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('reservation_number')
    parser.add_argument('--db')
    args = parser.parse_args()
    if not args.reservation_number.strip(): raise ValueError('reservation_number é obrigatório.')
    path = database_path(args.db)
    print('Banco: ' + str(path))
    print('Isso remove somente uncertain, failed e encoding da reserva informada.')
    confirm = input('Confirmação (RESET ' + args.reservation_number + '): ')
    code = reset(path, args.reservation_number, confirm)
    if code: raise SystemExit(code)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('ERRO: ' + str(error), file=sys.stderr)
        sys.exit(1)
