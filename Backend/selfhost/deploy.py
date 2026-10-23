#!/usr/bin/env python3
"""Upload Backend/ to the new server; never changes an existing backend or DNS."""
import argparse
import datetime
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='New server IPv4 address or hostname')
    parser.add_argument('--identity', type=Path, required=True, help='Local deployment SSH private key')
    parser.add_argument('--known-hosts', type=Path, help='SSH host-key file (defaults beside the identity file)')
    parser.add_argument('--bootstrap', action='store_true', help='Install Docker on a fresh Ubuntu 24.04 server')
    parser.add_argument('--activate', action='store_true', help='Start the new stack after its private configuration is installed')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{0,252}', args.host):
        parser.error('Invalid host')
    root = Path(__file__).resolve().parents[2]
    revision = subprocess.check_output(['git', 'rev-parse', '--short=12', 'HEAD'], cwd=root, text=True).strip()
    release = revision + '-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    target = 'root@' + args.host
    known_hosts = args.known_hosts or args.identity.resolve().parent / 'known_hosts'
    ssh_options = ['-i', str(args.identity.resolve()), '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=' + str(known_hosts.resolve())]
    ssh = ['ssh', *ssh_options, target]
    backend = root / 'Backend'
    ignored = {'node_modules', 'build', 'secrets', 'imports', 'data', '__pycache__'}
    with tempfile.TemporaryDirectory(prefix='bound-deploy-') as temporary:
        archive = Path(temporary) / (release + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            for file in sorted(backend.rglob('*')):
                relative = file.relative_to(backend)
                if file.is_symlink() or not file.is_file() or any(part in ignored for part in relative.parts):
                    continue
                if file.name.startswith('.env') or file.suffix in {'.log', '.pyc'}:
                    continue
                tar.add(file, arcname=str(Path('Backend') / relative), recursive=False)
        remote = '/opt/bound/releases/' + release
        subprocess.run(ssh + ['install -d -m 0700 ' + shlex.quote(remote)], check=True)
        subprocess.run(['scp', *ssh_options, str(archive), target + ':' + remote + '/backend.tar.gz'], check=True)
        subprocess.run(ssh + ['tar -xzf ' + remote + '/backend.tar.gz -C ' + remote], check=True)
        if args.bootstrap:
            subprocess.run(ssh + ['bash ' + remote + '/Backend/selfhost/bootstrap.sh'], check=True)
        if args.activate:
            # Secrets live outside release trees, so deployment never replaces
            # the database/session/Dropbox encryption keys during an update.
            command = '\n'.join([
                'set -eu',
                'test -f /opt/bound/config/.env',
                'test -f /opt/bound/config/secrets/nakama.yml',
                'ln -s /opt/bound/config/.env ' + remote + '/Backend/selfhost/.env',
                'ln -s /opt/bound/config/secrets ' + remote + '/Backend/selfhost/secrets',
                'cd ' + remote + '/Backend/selfhost',
                'docker compose build',
                'docker compose up -d --wait --wait-timeout 180',
                'ln -sfn ' + remote + ' /opt/bound/current',
            ])
            subprocess.run(ssh + [command], check=True)
        print('Prepared release ' + remote + ('; new backend started.' if args.activate else '; activation not requested.'))
        print('Existing backend and DNS were not changed.')


if __name__ == '__main__':
    main()
