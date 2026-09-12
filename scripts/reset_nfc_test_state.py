#!/usr/bin/env python3
"""Remove only non-confirmed NFC attempts for one explicitly named reservation."""
import argparse
import json
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


COMPOSE = ['docker', 'compose', '-f', 'compose.yml', '-f', 'compose.host-edge.yml', '-f', 'compose.face-real-test.yml', '-f', 'compose.nfc-bis.yml']


def container_rows(reservation_number):
    script = r'''const Database=require('better-sqlite3'); const db=new Database('/app/data/totem.sqlite', {readonly:true}); const r=db.prepare('SELECT id,reservation_number FROM reservations WHERE reservation_number=?').get(process.argv[1]); if(!r) throw Error('Reserva não encontrada.'); const rows=db.prepare("SELECT id,guest_id,guest_name,status,wristband_code FROM wristband_credentials WHERE reservation_id=? AND status IN ('uncertain','failed','encoding')").all(r.id); console.log(JSON.stringify({reservation:r,rows}));'''
    result = subprocess.run(COMPOSE + ['exec', '-T', 'totem-api', 'node', '-e', script, '--', reservation_number], text=True, capture_output=True)
    if result.returncode: raise RuntimeError('Não foi possível consultar o banco dentro do container.')
    return json.loads(result.stdout.strip())


def container_reset(reservation_number):
    script = r'''const Database=require('better-sqlite3'); const db=new Database('/app/data/totem.sqlite'); const r=db.prepare('SELECT id FROM reservations WHERE reservation_number=?').get(process.argv[1]); if(!r) throw Error('Reserva não encontrada.'); const tx=db.transaction(()=>{const rows=db.prepare("SELECT id,guest_id FROM wristband_credentials WHERE reservation_id=? AND status IN ('uncertain','failed','encoding')").all(r.id); for(const row of rows){if(db.prepare("SELECT 1 FROM wristband_credentials WHERE guest_id=? AND status='encoded'").get(row.guest_id)) continue; db.prepare('UPDATE guests SET wristband_code=NULL WHERE id=? AND reservation_id=?').run(row.guest_id,r.id); db.prepare("DELETE FROM wristband_credentials WHERE id=? AND status IN ('uncertain','failed','encoding')").run(row.id);}}); tx(); console.log('Estado de teste removido. Nenhuma gravação NFC foi executada.');'''
    result = subprocess.run(COMPOSE + ['exec', '-T', 'totem-api', 'node', '-e', script, '--', reservation_number], text=True, capture_output=True)
    if result.returncode: raise RuntimeError('Não foi possível alterar o estado do banco dentro do container.')
    print(result.stdout.strip())


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
    try:
        path = database_path(args.db)
        print('Banco: ' + str(path))
        print('Isso remove somente uncertain, failed e encoding da reserva informada.')
        confirm = input('Confirmação (RESET ' + args.reservation_number + '): ')
        code = reset(path, args.reservation_number, confirm)
    except (PermissionError, sqlite3.OperationalError):
        summary = container_rows(args.reservation_number)
        print('Banco protegido pelo volume Docker; operação será executada dentro do container totem-api.')
        print('Reserva: ' + summary['reservation']['reservation_number'])
        print('Tentativas removíveis: ' + str(len(summary['rows'])))
        for row in summary['rows']: print(f"guest_id={row['guest_id']} status={row['status']} code_present={bool(row['wristband_code'])}")
        if not summary['rows']: return
        confirm = input('Confirmação (RESET ' + args.reservation_number + '): ')
        if confirm != 'RESET ' + args.reservation_number:
            print('Operação cancelada. Digite exatamente: RESET ' + args.reservation_number)
            raise SystemExit(2)
        container_reset(args.reservation_number)
        return
    if code: raise SystemExit(code)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('ERRO: ' + str(error), file=sys.stderr)
        sys.exit(1)
