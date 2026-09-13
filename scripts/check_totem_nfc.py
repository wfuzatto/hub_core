#!/usr/bin/env python3
"""Validate and print only safe Totem NFC status fields."""
import json
import sys


def safe_status(data):
    return {
        'provider': str(data.get('provider', '')).lower() or 'missing',
        'online': data.get('online'),
        'configured': data.get('configured'),
        'ready_for_write': data.get('ready_for_write'),
        'code': data.get('code'),
        'error': data.get('error'),
        'reader_present': data.get('reader_present'),
        'writes_enabled': data.get('writes_enabled'),
        'hotel_password_configured': data.get('hotel_password_configured'),
        'process_architecture': data.get('process_architecture'),
    }


def main():
    data = json.load(sys.stdin)
    status = safe_status(data)
    provider = status['provider']

    if provider != 'bis_api':
        print('ERRO: Totem iniciou com provider diferente de bis_api.', file=sys.stderr)
        print(json.dumps(status, ensure_ascii=False, separators=(',', ':')), file=sys.stderr)
        return 1

    if data.get('configured') is not True:
        print('ERRO: provider=bis_api, mas a configuração efetiva foi rejeitada pelo Totem.', file=sys.stderr)
        print(json.dumps(status, ensure_ascii=False, separators=(',', ':')), file=sys.stderr)
        return 1

    if data.get('online') is not True:
        print('ERRO: provider=bis_api configurado, porém o Totem não consegue alcançar o BisApi.', file=sys.stderr)
        print(json.dumps(status, ensure_ascii=False, separators=(',', ':')), file=sys.stderr)
        return 1

    print(json.dumps({
        'provider': provider,
        'bis_api_url': 'configured',
        'online': True,
        'configured': True,
        'ready_for_write': data.get('ready_for_write') is True,
        'code': data.get('code'),
        'reader_present': data.get('reader_present'),
        'writes_enabled': data.get('writes_enabled'),
        'hotel_password_configured': data.get('hotel_password_configured'),
        'process_architecture': data.get('process_architecture'),
        'confirmation_length': 'not exposed by runtime status',
        'card_present': data.get('card_present', 'not_required')
    }, ensure_ascii=False, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print('ERRO: resposta inválida em /api/access-control/status: ' + str(exc), file=sys.stderr)
        sys.exit(1)
