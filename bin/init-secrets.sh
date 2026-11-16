#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets

# Next to this checkout, as on the hosts, or one level further up when the repos are grouped per application
# (fgv/fgv-infra-deploy, fgv/spexify/fgv-spexify-deploy, ...); INFRA_DEPLOY overrides both
if [[ -n ${INFRA_DEPLOY:-} ]]; then
  infra_deploy=$INFRA_DEPLOY
elif [[ -d ../fgv-infra-deploy ]]; then
  infra_deploy=../fgv-infra-deploy
else
  infra_deploy=../../fgv-infra-deploy
fi

generate() {
  local name=$1 value=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  else
    printf '%s' "$value" > "secrets/$name"
    echo "created secrets/$name"
  fi
}

# Client secrets are made by fgv-infra-deploy, which sets them in the realm
copy_client_secret() {
  local name=$1 client=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  elif [[ -s $infra_deploy/secrets/clients/$client ]]; then
    cp "$infra_deploy/secrets/clients/$client" "secrets/$name"
    echo "copied secrets/$name from $infra_deploy"
  else
    echo "missing secrets/$name: run bin/init-secrets.sh in fgv-infra-deploy first, or set INFRA_DEPLOY" >&2
  fi
}

random() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

generate MYSQL_ROOT_PASSWORD "$(random 32)"
generate MYSQL_USER_PASSWORD "$(random 32)"
# Encrypts the app passwords. Losing it makes every app password stop working; back it up with the database.
generate API_APP_PASSWORD_ENCRYPTION_KEY "$(openssl rand -base64 32)"
# Signs the links to audio and downloads; changing it only makes open players ask for new links
generate API_MEDIA_SIGNING_KEY "$(random 48)"
copy_client_secret KEYCLOAK_CLIENT_SECRET fgv-spexify
copy_client_secret KEYCLOAK_SERVICE_CLIENT_SECRET fgv-spexify-service
# The sample data's Subsonic app password
if grep -qx 'API_IMPORT_SAMPLE_DATA=true' .env 2>/dev/null; then
  generate SAMPLE_APP_PASSWORD "$(random 24)"
else
  touch secrets/SAMPLE_APP_PASSWORD
fi
generate WEB_AUTH_SECRET "$(random 48)"
if [[ ! -s secrets/cloudflared.env ]]; then
  printf 'TUNNEL_TOKEN=\n' > secrets/cloudflared.env
  echo "created secrets/cloudflared.env (staging only: paste the tunnel token into it)"
fi

chmod 700 secrets
find secrets -maxdepth 1 -type f ! -name '*.env' -exec chmod 644 {} +
chmod 600 secrets/*.env
