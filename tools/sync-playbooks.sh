#!/usr/bin/env bash
# Copy the example playbooks from seed/playbooks/ into the Gitea repo infra/playbooks.
# Adds new files and updates files that came from here; never deletes your files.
# Files you changed in Gitea are overwritten only with --force.
#   sudo ./tools/sync-playbooks.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."
source lib/common.sh
load_config
FORCE=${1:-}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
auth=$(printf '%s:%s' "$POC_ADMIN_USER" "$POC_ADMIN_PASSWORD" | base64 -w0)
g() { git -C "$tmp/repo" -c http.extraHeader="Authorization: Basic ${auth}" "$@"; }

git -c http.extraHeader="Authorization: Basic ${auth}" clone -q "${GITEA_URL}/infra/playbooks.git" "$tmp/repo"

changed=0
while IFS= read -r -d '' src; do
  rel=${src#seed/playbooks/}
  dst="$tmp/repo/$rel"
  if [[ ! -e $dst ]]; then
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; ok "added   $rel"; changed=1
  elif ! cmp -s "$src" "$dst"; then
    # Was the Gitea copy edited by someone since it was last synced from here?
    if [[ $FORCE != --force ]] && g log --format=%an -- "$rel" | grep -qv '^PoC Bootstrap$'; then
      warn "skipped $rel (edited in Gitea - use --force to overwrite)"
    else
      cp "$src" "$dst"; ok "updated $rel"; changed=1
    fi
  fi
done < <(find seed/playbooks -type f -print0)

if (( changed )); then
  g add -A
  g -c user.name="PoC Bootstrap" -c user.email="$POC_ADMIN_EMAIL" commit -q -m "Sync example playbooks from poc-stack"
  g push -q origin HEAD
  ok "pushed to ${GITEA_URL}/infra/playbooks - AWX picks it up on the next job launch"
else
  ok "nothing to sync - Gitea already has the latest examples"
fi
