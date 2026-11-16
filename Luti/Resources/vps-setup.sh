#!/usr/bin/env bash
# Luti self-hosted MCP: run as root on an otherwise unused Ubuntu/Debian VPS.
set -euo pipefail
domain='__LUTI_DOMAIN__'
public_key='__LUTI_PUBLIC_KEY__'
remote_port='__LUTI_REMOTE_PORT__'

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep '^Status: active$' >/dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  echo 'Run this setup as root on the VPS.' >&2
  exit 1
fi
. /etc/os-release
case "$ID" in ubuntu|debian) ;; *) echo 'Only Ubuntu and Debian are supported.' >&2; exit 1 ;; esac
if [ -f /etc/caddy/Caddyfile ] && ! grep -q '^# Luti self-hosted MCP' /etc/caddy/Caddyfile; then
  echo 'An existing Caddy configuration was found. Use the manual deployment guide instead.' >&2
  exit 1
fi
if ! [ -f /etc/ssh/sshd_config.d/60-luti.conf ]; then
  if id luti >/dev/null 2>&1; then echo 'The luti user already exists; inspect it before setup.' >&2; exit 1; fi
  if ss -ltnH | awk '{print $4}' | grep -Eq ':(80|443)$'; then
    echo 'Ports 80/443 are in use. Use the manual deployment guide instead.' >&2
    exit 1
  fi
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y caddy openssh-server openssl
if ! grep -Eiq '^Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  echo 'sshd_config does not load drop-in files; enable its standard Include before continuing.' >&2
  exit 1
fi

if ! id luti >/dev/null 2>&1; then
  useradd --user-group --create-home --shell /usr/sbin/nologin luti
  # Keep the account usable for public-key authentication, with an unknown random password.
  password_hash=$(openssl passwd -6 "$(openssl rand -hex 32)")
  usermod --password "$password_hash" luti
  unset password_hash
fi
install -d -m 700 -o luti -g luti /home/luti/.ssh
printf 'restrict,port-forwarding,permitlisten="127.0.0.1:%s" %s\n' "$remote_port" "$public_key" > /home/luti/.ssh/authorized_keys
chown luti:luti /home/luti/.ssh/authorized_keys
chmod 600 /home/luti/.ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/60-luti.conf <<LUTI_SSH
Match User luti
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding remote
    AllowStreamLocalForwarding no
    PermitListen 127.0.0.1:$remote_port
    GatewayPorts no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
    MaxSessions 0
Match all
LUTI_SSH
sshd -t

cat > /etc/caddy/Caddyfile <<LUTI_CADDY
# Luti self-hosted MCP
$domain {
    header Cache-Control "no-store"
    reverse_proxy 127.0.0.1:$remote_port {
        flush_interval -1
    }
}
LUTI_CADDY
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
configure_firewall
systemctl reload ssh
systemctl enable --now caddy
systemctl reload caddy

echo
echo 'Optional: paste this complete server host public key into Luti > SSH settings (verify it from this VPS console):'
awk '{print $1 " " $2}' /etc/ssh/ssh_host_ed25519_key.pub
echo
echo "MCP URL: https://$domain/mcp"
echo 'If UFW was already active, the script allowed TCP 80/443.'
echo 'In the cloud security group, allow TCP 22 (or your SSH port), 80 and 443.'
echo 'For other system firewalls, allow TCP 80/443 manually. Keep port 39393 private.'
echo 'Point the domain A/AAAA records to this VPS. Start with DNS-only; enable orange-cloud Full (strict) after HTTPS works.'
echo 'Configuration validation does not confirm certificate issuance. Caddy still needs public access on TCP 80/443.'
echo 'Save settings and start Luti on the Mac. Wait for Connected, then add the MCP URL to your AI client and approve OAuth in Luti.'
