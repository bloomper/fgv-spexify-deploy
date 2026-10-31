#!/usr/bin/env bash
# Copies the media that cannot be recreated (published and unpublished tracks, covers) and Navidrome's database (the
# users' stars and playlists) to off-host storage with restic. RESTIC_REPOSITORY and RESTIC_PASSWORD_FILE must be set,
# e.g. in the environment of the cron job.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE}"

restic backup --tag spexify ./data/media/music ./data/media/unpublished ./data/media/covers ./data/navidrome ./secrets/APP_PASSWORD_KEY
restic forget --tag spexify --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
