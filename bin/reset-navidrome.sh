#!/usr/bin/env bash
# Starts Navidrome from scratch: deletes its database (users, stars, playlists, play counts) and lets it scan the music
# folder again. For staging, where the sample data import replaces the catalogue but not Navidrome's database.
set -euo pipefail

cd "$(dirname "$0")/.."

if grep -qx 'DEPLOY_ENV=production' .env 2>/dev/null; then
  echo "refusing in production: this deletes every user's stars and playlists" >&2
  exit 1
fi
docker compose stop spexify-navidrome
rm -rf -- ./data/navidrome/*
docker compose up -d spexify-navidrome
docker compose restart spexify-api
echo "Navidrome starts empty; Spexify asks it to scan"
