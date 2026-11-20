#!/usr/bin/env bash
# Runs inside the container started by verify.sh.
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$*"; }
expect_mode() { [[ $(stat -c '%a %U:%G' "$1") == "$2" ]] || fail "$1 is $(stat -c '%a %U:%G' "$1"), want $2"; }

until [[ $(systemctl is-system-running 2>/dev/null) =~ ^(running|degraded)$ ]]; do sleep 1; done

useradd -m pi
# Same shape as the real first release: an annotated tag named like v0.1.0, version from pyproject.toml.
tag=v$(sed -n 's/^version = "\(.*\)"$/\1/p' /src/pyproject.toml)
origin=/srv/origin
mkdir -p "$origin"
tar -C /src --exclude=.git --exclude=.venv --exclude=.kitchen --exclude='*.db' -cf - . | tar -C "$origin" -xf -
git -C "$origin" init -q -b main
git -C "$origin" -c user.name=v -c user.email=v@v add -A
git -C "$origin" -c user.name=v -c user.email=v@v commit -qm verify
git -C "$origin" -c user.name=v -c user.email=v@v tag -a -m "olvar-gateway $tag" "$tag"
chown -R pi:pi "$origin"
sudo -u pi git clone -q "$origin" /home/pi/olvar-gateway
repo=/home/pi/olvar-gateway

"$repo/deploy/install.sh" >/tmp/install1.log 2>&1 || { cat /tmp/install1.log; fail "first install.sh"; }
ok "install.sh (first run)"
grep -q "fill in /etc/olvar-gateway/gateway.env" /tmp/install1.log || fail "install.sh did not ask for gateway.env"
"$repo/deploy/install.sh" >/tmp/install2.log 2>&1 || { cat /tmp/install2.log; fail "second install.sh"; }
ok "install.sh is idempotent (second run)"
[[ -z $(find "$repo" -user root) ]] || fail "install.sh left root-owned files in the clone"

id olvar | grep -q 'groups=.*(olvar)' || fail "olvar user"
expect_mode /etc/olvar-gateway "750 root:olvar"
expect_mode /etc/olvar-gateway/gateway.env "640 root:olvar"
expect_mode /etc/mosquitto/acl "600 mosquitto:mosquitto"
[[ $(grep -c 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf) == 1 ]] || fail "nftables include not added exactly once"
ok "user, permissions, nftables include"

systemd-analyze verify /etc/systemd/system/olvar-gateway.service
ok "systemd-analyze verify"
nft -c -f /etc/nftables.conf
nft list table inet olvar | grep -Eq 'ip saddr [0-9.]+/[0-9]+ tcp dport 1883 accept' || fail "nftables olvar table"
ok "nftables rules loaded"
grep -q '^SystemMaxUse=50M' /etc/systemd/journald.conf.d/olvar.conf || fail "journald cap"

# The exact commands from docs/DEPLOY.md, with passwords fed on stdin instead of typed.
add_gateway_user() {
  if sudo test -f /etc/mosquitto/passwd; then
    printf 'gwpass\ngwpass\n' | sudo mosquitto_passwd /etc/mosquitto/passwd olvar-gateway
  else
    printf 'gwpass\ngwpass\n' | sudo mosquitto_passwd -c /etc/mosquitto/passwd olvar-gateway
  fi
  sudo chown mosquitto:mosquitto /etc/mosquitto/passwd && sudo chmod 0600 /etc/mosquitto/passwd
}
add_gateway_user
printf 'devpass\ndevpass\n' | sudo mosquitto_passwd /etc/mosquitto/passwd olvar-a1b2c3
sudo chown mosquitto:mosquitto /etc/mosquitto/passwd && sudo chmod 0600 /etc/mosquitto/passwd
add_gateway_user
grep -q '^olvar-a1b2c3:' /etc/mosquitto/passwd || fail "re-adding the gateway user wiped the device user"
expect_mode /etc/mosquitto/passwd "600 mosquitto:mosquitto"
systemctl restart mosquitto
systemctl is-active -q mosquitto || { journalctl -u mosquitto --no-pager | tail -20; fail "mosquitto not active"; }
ok "mosquitto users and broker"

sub() { timeout 3 mosquitto_sub -h 127.0.0.1 -u olvar-gateway -P gwpass -t 'olvar/v1/+/status' -C 1 -W 2 || true; }
mosquitto_pub -h 127.0.0.1 -u olvar-a1b2c3 -P devpass -t olvar/v1/olvar-a1b2c3/status -m online -r -q 1
[[ $(sub) == online ]] || fail "device could not publish its own status"
mosquitto_pub -h 127.0.0.1 -u olvar-a1b2c3 -P devpass -t olvar/v1/olvar-a1b2c3/status -n -r -q 1
mosquitto_pub -h 127.0.0.1 -u olvar-a1b2c3 -P devpass -t olvar/v1/olvar-ffffff/status -m spoof -r -q 1 || true
[[ -z $(sub) ]] || fail "device published to another device's topic"
if mosquitto_pub -h 127.0.0.1 -t olvar/v1/anon/status -m x -q 1 2>/dev/null; then fail "anonymous publish accepted"; fi
ok "ACL: own topic allowed, other topic denied, anonymous refused"

sed -i -e 's#^SUPABASE_URL=.*#SUPABASE_URL=http://127.0.0.1:9#' \
  -e 's#^SUPABASE_SECRET_KEY=.*#SUPABASE_SECRET_KEY=sb_secret_verify#' \
  -e 's#^MQTT_PASSWORD=.*#MQTT_PASSWORD=gwpass#' /etc/olvar-gateway/gateway.env
systemctl restart olvar-gateway
sleep 5
mosquitto_pub -h 127.0.0.1 -u olvar-a1b2c3 -P devpass -t olvar/v1/olvar-a1b2c3/telemetry -q 1 \
  -f /src/contracts/examples/valid-full.json
sleep 3
systemctl is-active -q olvar-gateway || { journalctl -u olvar-gateway --no-pager | tail -30; fail "gateway not active"; }
status=$(sudo -u olvar env OUTBOX_PATH=/var/lib/olvar-gateway/outbox.db \
  /opt/olvar-gateway/venv/bin/python -m olvar_gateway status)
echo "$status"
grep -q '^queue_depth: [1-9]' <<<"$status" || { journalctl -u olvar-gateway --no-pager | tail -30; fail "reading not queued"; }
expect_mode /var/lib/olvar-gateway "750 olvar:olvar"
ok "service runs sandboxed, queues telemetry while Supabase is unreachable"

"$repo/deploy/update.sh" "$tag" >/tmp/update.log 2>&1 || { cat /tmp/update.log; fail "update.sh"; }
grep -q "checked out $tag" /tmp/update.log || fail "update.sh did not check out the tag"
grep -q "^olvar-gateway ${tag#v} ($tag)$" /tmp/update.log || fail "update.sh did not install ${tag#v} at $tag"
systemctl is-active -q olvar-gateway || fail "gateway not active after update.sh"
ok "update.sh $tag"
echo "ALL CHECKS PASSED"
