#!/usr/bin/env bash
# Installs or re-installs the gateway on Raspberry Pi OS Lite 64-bit (Trixie). Safe to run again.
# Usage: sudo deploy/install.sh        (optional: OLVAR_LAN_SUBNET=192.168.1.0/24 to skip subnet detection)
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEPLOY_DIR=$REPO_DIR/deploy
APP_DIR=/opt/olvar-gateway
VENV=$APP_DIR/venv
ETC_DIR=/etc/olvar-gateway
ENV_FILE=$ETC_DIR/gateway.env
PASSWD_FILE=/etc/mosquitto/passwd
NFT_FILE=/etc/nftables.d/olvar.nft
NFT_INCLUDE='include "/etc/nftables.d/*.nft"'

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Containers used for verification have no running systemd; everything else still gets installed.
has_systemd() { [[ -d /run/systemd/system ]]; }

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0"

say "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates git iproute2 mosquitto mosquitto-clients nftables python3 python3-venv

say "Creating the olvar system user"
if ! id -u olvar >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin olvar
fi

say "Installing the gateway into $VENV"
install -d -m 0755 "$APP_DIR"
[[ -x $VENV/bin/python ]] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --disable-pip-version-check --no-input --require-hashes \
  -r "$REPO_DIR/requirements.txt"
"$VENV/bin/pip" install -q --disable-pip-version-check --no-input --no-deps --force-reinstall \
  --no-cache-dir "$REPO_DIR"
version=$("$VENV/bin/python" -c 'import importlib.metadata as m; print(m.version("olvar-gateway"))')
echo "olvar-gateway $version ($(git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" describe --tags --always 2>/dev/null || echo unknown))"

say "Configuration in $ETC_DIR"
install -d -m 0750 -o root -g olvar "$ETC_DIR"
if [[ ! -f $ENV_FILE ]]; then
  install -m 0640 -o root -g olvar "$DEPLOY_DIR/gateway.env.example" "$ENV_FILE"
  echo "created $ENV_FILE from the example"
fi
chown root:olvar "$ENV_FILE"
chmod 0640 "$ENV_FILE"

say "systemd unit and journald cap"
install -m 0644 "$DEPLOY_DIR/systemd/olvar-gateway.service" /etc/systemd/system/olvar-gateway.service
install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "$DEPLOY_DIR/journald/olvar.conf" /etc/systemd/journald.conf.d/olvar.conf

say "Mosquitto"
install -m 0644 "$DEPLOY_DIR/mosquitto/olvar.conf" /etc/mosquitto/conf.d/olvar.conf
install -m 0600 -o mosquitto -g mosquitto "$DEPLOY_DIR/mosquitto/acl" /etc/mosquitto/acl
if [[ -f $PASSWD_FILE ]]; then
  chown mosquitto:mosquitto "$PASSWD_FILE"
  chmod 0600 "$PASSWD_FILE"
fi

say "Firewall: MQTT port 1883 only from the LAN"
lan4=${OLVAR_LAN_SUBNET:-}
if [[ -z $lan4 ]]; then
  dev=$(ip -o -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [[ -n $dev ]] && lan4=$(ip -o -4 route show dev "$dev" proto kernel scope link | awk '{print $1; exit}')
fi
[[ $lan4 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
  || die "could not detect the LAN subnet; run again with OLVAR_LAN_SUBNET=192.168.1.0/24 (your network)"
echo "LAN subnet: $lan4"
install -d -m 0755 /etc/nftables.d
sed "s|@LAN4@|$lan4|" "$DEPLOY_DIR/nftables/olvar.nft" >"$NFT_FILE.tmp"
chmod 0644 "$NFT_FILE.tmp"
mv "$NFT_FILE.tmp" "$NFT_FILE"
grep -qxF "$NFT_INCLUDE" /etc/nftables.conf || printf '\n%s\n' "$NFT_INCLUDE" >>/etc/nftables.conf

if ! has_systemd; then
  say "No running systemd: files installed, services not started"
  exit 0
fi

say "Starting services"
systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable -q nftables mosquitto olvar-gateway
systemctl restart nftables

next=()
if [[ -f $PASSWD_FILE ]]; then
  systemctl restart mosquitto
else
  next+=("create the MQTT users (docs/DEPLOY.md, step 'MQTT users'); Mosquitto starts after that")
fi
if grep -Eq '^[A-Z_]+=.*replace_me' "$ENV_FILE"; then
  next+=("fill in $ENV_FILE: sudo nano $ENV_FILE")
fi
if ((${#next[@]} == 0)); then
  systemctl restart olvar-gateway
  sleep 3
  systemctl --no-pager --lines=5 status olvar-gateway || true
else
  systemctl stop olvar-gateway 2>/dev/null || true
  say "Not started yet. Next:"
  printf '  - %s\n' "${next[@]}"
  echo "  - then: sudo systemctl restart mosquitto olvar-gateway"
fi
