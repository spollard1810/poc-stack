#!/usr/bin/env bash
# Copy the example playbooks from seed/playbooks/ into the Gitea repo infra/playbooks.
# Adds new files and updates files that came from here; never deletes your files.
# Files you changed in Gitea are overwritten only with --force.
#   sudo ./tools/sync-playbooks.sh [--force]
exec bash "$(dirname "$0")/sync-repo.sh" "$(dirname "$0")/../seed/playbooks" infra/playbooks "$@"
