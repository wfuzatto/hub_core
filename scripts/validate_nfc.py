#!/usr/bin/env python3
"""Validate effective Compose environment from stdin without printing secrets."""
import json
import re
import sys
from urllib.parse import urlsplit


def validate(env):
    provider = env.get('HOTEL_CARD_PROVIDER', 'bis_api')
    if provider == 'mock':
        return []
    if provider != 'bis_api':
        return ['HOTEL_CARD_PROVIDER deve ser bis_api (real) ou mock (teste explícito).']
    errors = []
    for name in ['BIS_API_URL', 'BIS_API_WRITE_CONFIRMATION', 'HOTEL_ACCESS_CHECKIN_TIME', 'HOTEL_ACCESS_CHECKOUT_TIME', 'HOTEL_ACCESS_UTC_OFFSET']:
        if not str(env.get(name) or '').strip():
            errors.append(name + ' obrigatório no modo real.')
    try:
        url = urlsplit(env.get('BIS_API_URL') or '')
        if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment or re.search(r'\s', url.geturl()):
            raise ValueError()
        if url.port is not None and not 1 <= url.port <= 65535:
            raise ValueError()
        if url.hostname in ('127.0.0.1', 'localhost', '::1'):
            errors.append('BIS_API_URL deve apontar ao Windows na LAN, não ao loopback do container.')
    except (ValueError, TypeError):
        errors.append('BIS_API_URL inválida; use http(s)://HOST_WINDOWS:PORTA sem credenciais.')
    for name in ['HOTEL_ACCESS_CHECKIN_TIME', 'HOTEL_ACCESS_CHECKOUT_TIME']:
        if not re.fullmatch(r'([01]\d|2[0-3]):[0-5]\d', str(env.get(name) or '')):
            errors.append(name + ' deve usar HH:MM.')
    if not re.fullmatch(r'(Z|[+-]([01]\d|2[0-3]):[0-5]\d)', str(env.get('HOTEL_ACCESS_UTC_OFFSET') or '')):
        errors.append('HOTEL_ACCESS_UTC_OFFSET deve usar Z ou ±HH:MM.')
    return errors


if __name__ == '__main__':
    try:
        env = json.load(sys.stdin)['services']['totem-api']['environment']
        errors = validate(env)
    except Exception:
        errors = ['Não foi possível validar a configuração NFC efetiva do Compose.']
    for error in errors:
        print('ERRO: ' + error, file=sys.stderr)
    if errors:
        sys.exit(1)
    print('NFC: configuração efetiva validada; provider=' + env.get('HOTEL_CARD_PROVIDER', 'bis_api'))
