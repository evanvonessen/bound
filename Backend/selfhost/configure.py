#!/usr/bin/env python3
"""Generate local deployment secrets without printing them or overwriting any."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hostname', required=True)
    parser.add_argument('--tls-email', required=True)
    parser.add_argument('--directory', type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    if not re.fullmatch(r'(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', args.hostname) or '.' not in args.hostname:
        parser.error('Use a DNS hostname, without a scheme or path')
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', args.tls_email):
        parser.error('Use a valid TLS contact email')
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    if (directory / '.env').exists() or (directory / 'secrets/nakama.yml').exists():
        parser.error('Existing secrets found; refusing to replace credentials')
    secure = directory / 'secrets'
    secure.mkdir(mode=0o700, exist_ok=True)
    values = {
        'BOUND_HOSTNAME': args.hostname,
        'TLS_EMAIL': args.tls_email,
        'BOUND_PUBLIC_URL': 'https://' + args.hostname,
        'PUBLIC_URL': 'https://' + args.hostname,
        'POSTGRES_PASSWORD': secrets.token_hex(32),
        'NAKAMA_SERVER_KEY': secrets.token_hex(32),
        'NAKAMA_HTTP_KEY': secrets.token_hex(32),
        'BOUND_GATEWAY_SECRET': secrets.token_hex(32),
        'BOUND_NAKAMA_BRIDGE_SECRET': secrets.token_hex(32),
        'BOUND_AUTH_ENCRYPTION_KEY': base64.b64encode(secrets.token_bytes(32)).decode(),
        'NAKAMA_INTERNAL_URL': 'http://nakama:7350',
        'NAKAMA_HTTP_URL': 'http://nakama:7350',
        'RESEND_FROM': 'Bound <noreply@auth.evanvonessen.com>',
        'RESEND_API_KEY': '',
        'AGORA_APP_ID': '',
        'AGORA_APP_CERTIFICATE': '',
        'DROPBOX_APP_KEY': '',
        # Preserve the existing key when importing encrypted Dropbox grants.
        'DROPBOX_ENCRYPTION_KEY': '',
        'APNS_KEY_ID': '', 'APNS_TEAM_ID': '', 'APNS_PRIVATE_KEY': '',
        'FILE_MAX_BYTES': '67108864', 'FILE_OWNER_BYTES': '134217728',
        'FILE_TOTAL_BYTES': '536870912', 'FILE_TTL_SECONDS': '3600',
    }
    values['DATABASE_URL'] = 'postgresql://nakama:' + values['POSTGRES_PASSWORD'] + '@postgres:5432/nakama'
    runtime = {
        'name': 'bound', 'data_dir': '/nakama/data', 'logger': {'level': 'INFO'},
        'database': {'address': ['nakama:' + values['POSTGRES_PASSWORD'] + '@postgres:5432/nakama'], 'max_open_conns': 15, 'max_idle_conns': 5},
        'runtime': {'js_entrypoint': 'index.js', 'http_key': values['NAKAMA_HTTP_KEY'],
                    'env': ['BOUND_ACCOUNT_MODE=nakama', 'BOUND_GATEWAY_SECRET=' + values['BOUND_GATEWAY_SECRET'],
                            'BOUND_NAKAMA_BRIDGE_SECRET=' + values['BOUND_NAKAMA_BRIDGE_SECRET']]},
        'socket': {'server_key': values['NAKAMA_SERVER_KEY'], 'max_message_size_bytes': 32768, 'max_request_size_bytes': 65536},
        'session': {'encryption_key': secrets.token_hex(32), 'refresh_encryption_key': secrets.token_hex(32),
                    'token_expiry_sec': 3600, 'refresh_token_expiry_sec': 2592000},
        'console': {'address': '127.0.0.1', 'username': 'bound-admin', 'password': secrets.token_hex(32), 'signing_key': secrets.token_hex(32)},
    }
    # JSON is valid YAML and avoids an extra bootstrap dependency.
    write_private(secure / 'nakama.yml', json.dumps(runtime, indent=2) + '\n')
    write_private(directory / '.env', ''.join(k + '=' + json.dumps(v) + '\n' for k, v in values.items()))
    print('Deployment configuration created. Set integration credentials in the private .env before activation.')


if __name__ == '__main__':
    main()
