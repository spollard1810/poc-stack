#!/usr/bin/env bash
# Copy files from a local directory into a Gitea repo (pushes to main).
# Adds new files and updates files that came from here; never deletes files.
# Files someone else changed in Gitea are only overwritten with --force.
#   sudo ./tools/sync-repo.sh <source-dir> <org/repo> [--force]
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh
load_config
SRC=${1:?source dir}; REPO=${2:?org/repo}; FORCE=${3:-}
SRC=$(cd "$SRC" && pwd)

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
auth=$(printf '%s:%s' "$POC_ADMIN_USER" "$POC_ADMIN_PASSWORD" | base64 -w0)
g() { git -C "$tmp/repo" -c http.extraHeader="Authorization: Basic ${auth}" "$@"; }

git -c http.extraHeader="Authorization: Basic ${auth}" clone -q "${GITEA_URL}/${REPO}.git" "$tmp/repo" 2>/dev/null
if ! g rev-parse HEAD >/dev/null 2>&1; then
  g checkout -q -b main   # empty repo: first commit creates main
fi

changed=0
while IFS= read -r -d '' src; do
  rel=${src#"$SRC"/}
  dst="$tmp/repo/$rel"
  if [[ ! -e $dst ]]; then
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; ok "${REPO}: added   $rel"; changed=1
  elif ! cmp -s "$src" "$dst"; then
    if [[ $FORCE != --force ]] && g log --format=%an -- "$rel" | grep -qv '^PoC Bootstrap$'; then
      warn "${REPO}: skipped $rel (changed in Gitea - use --force to overwrite)"
    else
      cp "$src" "$dst"; ok "${REPO}: updated $rel"; changed=1
    fi
  fi
done < <(find "$SRC" -type f -print0)

if (( changed )); then
  g add -A
  g -c user.name="PoC Bootstrap" -c user.email="$POC_ADMIN_EMAIL" commit -q -m "Sync from poc-stack"
  g push -q origin HEAD:main
  ok "${REPO}: pushed to ${GITEA_URL}/${REPO}"
else
  ok "${REPO}: already up to date"
fi
