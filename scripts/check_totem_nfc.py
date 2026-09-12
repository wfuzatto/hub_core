#!/usr/bin/env python3
"""Validate and print only safe Totem NFC status fields."""
import json
import sys


def main():
    data = json.load(sys.stdin)
    provider = str(data.get('provider', '')).lower()
    if provider != 'bis_api' or data.get('online') is not True:
        raise ValueError('provider')
    print(json.dumps({
        'provider': provider,
        'bis_api_url': 'configured',
        'confirmation_configured': data.get('configured') is True,
        'confirmation_length': 'not exposed by runtime status',
        'card_present': data.get('card_present', 'not_required')
    }, ensure_ascii=False, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('ERRO: o Totem não confirmou provider=bis_api.', file=sys.stderr)
        sys.exit(1)
