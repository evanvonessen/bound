#!/usr/bin/env bash
# Run once on the new Ubuntu 24.04 server. Does not touch the existing backend.
set -euo pipefail
test "$(id -u)" = 0 || { echo 'Run as root.' >&2; exit 1; }
source /etc/os-release
test "$ID" = ubuntu && test "$VERSION_ID" = 24.04 || { echo 'Ubuntu 24.04 is required.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ca-certificates curl ufw unattended-upgrades
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
# Only 80/443 are published by Compose. PostgreSQL, Nakama and the gateway
# have no published ports, including on IPv6; Docker cannot bypass that.
install -d -m 0700 /opt/bound
echo 'Host ready. Deploy Backend/ to /opt/bound/Backend and configure the new hostname.'
