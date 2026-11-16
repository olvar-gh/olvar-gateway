#!/usr/bin/env bash
# T9 verification without a Pi: shellcheck, then a Debian Trixie arm64 container booted with systemd that runs
# install.sh twice, the Mosquitto user commands from docs/DEPLOY.md, the service and update.sh.
# Usage: deploy/test/verify.sh   (needs docker and shellcheck)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
shellcheck deploy/*.sh deploy/test/*.sh
echo "shellcheck ok"

image=olvar-gateway-verify:trixie
docker build -q --platform linux/arm64 -t "$image" - <<'DOCKERFILE' >/dev/null
FROM debian:trixie
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      systemd systemd-sysv dbus sudo git ca-certificates iproute2 \
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE

name=${KEEP:-olvar-verify-$$}
trap '[[ -n ${KEEP:-} ]] || docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" --platform linux/arm64 --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "$PWD:/src:ro" "$image" >/dev/null
docker exec "$name" bash /src/deploy/test/in_container.sh
