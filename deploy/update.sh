#!/usr/bin/env bash
# Moves the Pi to a released tag and re-runs install.sh (pinned dependencies, config files, restart).
# Usage: sudo deploy/update.sh v0.2.0
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 <tag>"

owner=$(stat -c %U "$REPO_DIR")
# git refuses to work in a repository owned by another user, so it runs as the owner of the clone.
git_() { sudo -u "$owner" git -C "$REPO_DIR" "$@"; }

git_ fetch -q --tags --prune origin
tag=${1:-}
if [[ -z $tag ]]; then
  echo "usage: sudo $0 <tag>; newest tags:" >&2
  git_ tag --sort=-v:refname | head -n 5 >&2
  exit 1
fi
git_ rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || die "no tag named $tag"
[[ -z $(git_ status --porcelain --untracked-files=no) ]] \
  || die "the clone in $REPO_DIR has local changes; undo them first (git -C $REPO_DIR status)"

git_ -c advice.detachedHead=false checkout -q "refs/tags/$tag"
echo "checked out $tag"
exec "$REPO_DIR/deploy/install.sh"
