# Spexify Deploy

Docker Compose setup for running Spexify (server, web, MySQL and Navidrome) on a single host, next to
[spexregister-deploy][1] and [fgv-infra-deploy][2], which runs Keycloak and the shared network `fgv-<DEPLOY_ENV>`.

Cloudflare is used on staging only, and even there not for Spexify itself: it streams and downloads audio, which
Cloudflare's CDN terms restrict on the free plans, so on staging its hostname is **DNS-only** (not proxied by
Cloudflare). It is served by the **edge proxy** in `fgv-infra-deploy` (`compose.edge.yaml`): Caddy on ports 80 and 443
with Let's Encrypt. There is no tunnel overlay here. Production uses no Cloudflare at all; its reverse proxy serves
`WEB_HOST` (see *Production*).

```
Subsonic apps ─/rest──┐
Browser ──────────────┼─https─▶ edge-caddy (fgv-infra-deploy) ─┬─▶ spexify-api:8080   /rest/*
                      │                                       └─▶ spexify-web:3000   everything else
spexify-web ──▶ spexify-api ──▶ spexify-mysql
                spexify-api ──Remote-User──▶ spexify-navidrome:4533   (network "navidrome", internal)
                spexify-api ──▶ keycloak-server, spexregister-api, spexflix-api   (fgv network)
```

Navidrome is reachable only from the API, on an internal network where the API has a fixed address
(`NAVIDROME_SUBNET_PREFIX.10`), and it trusts the `Remote-User` header only from that address. It has no published
port and no route to the internet.

## Files

| File                     | Purpose                                                                          |
|--------------------------|----------------------------------------------------------------------------------|
| `compose.yaml`           | `spexify-mysql`, `spexify-navidrome`, `spexify-api`, `spexify-web`               |
| `staging.env.example`    | Template for `.env` on the staging host                                          |
| `production.env.example` | Template for `.env` on the production host                                       |
| `bin/init-secrets.sh`    | Generates secrets into `secrets/` and copies the client secrets from `fgv-infra-deploy` |
| `bin/backup-db.sh`       | Dumps the database into `backups/`, pruning dumps older than 14 days             |
| `bin/backup-media.sh`    | Backs up the media, Navidrome's database and the app password key with restic    |
| `bin/reset-navidrome.sh` | Starts Navidrome from scratch (not in production)                                |

| `.env` variable | Image                         | Source repo          |
|-----------------|-------------------------------|----------------------|
| `API_IMAGE`     | `bloomper/fgv-spexify-server` | `fgv-spexify-server` |
| `WEB_IMAGE`     | `bloomper/fgv-spexify-web`    | `fgv-spexify-web`    |

## 1. Host

- `fgv-infra-deploy` running with a realm that has the `fgv-spexify` and `fgv-spexify-service` clients, and its `.env`
  naming this deployment's `WEB_HOST` as `SPEXIFY_WEB_HOST`, because Keycloak only sends users back to that address.
  Its edge proxy (`compose.edge.yaml`) must run, with only ports 80 and 443 open on the host.
- `spexregister-deploy` running a `spexregister-server` release that knows the `MEDIA` role.
- A DNS record for `WEB_HOST` pointing at the host: DNS-only (grey cloud) on staging, where the domain is on Cloudflare.

## 2. Checkout and configuration

```shell
git clone https://github.com/bloomper/fgv-spexify-deploy.git
cd fgv-spexify-deploy

cp staging.env.example .env          # set the hostnames
bin/init-secrets.sh                  # copies the client secrets from ../fgv-infra-deploy
mkdir -p data/api/log_data data/media/music data/navidrome
sudo chown -R 1000:1000 data
docker compose up -d
```

| Variable                          | Purpose                                                                      |
|-----------------------------------|------------------------------------------------------------------------------|
| `WEB_HOST`                        | Spexify's address, for the web and for Subsonic apps                         |
| `KEYCLOAK_HOST`, `KEYCLOAK_REALM` | Keycloak's public address and realm                                          |
| `NAVIDROME_SUBNET_PREFIX`         | The internal network between the API and Navidrome, e.g. `172.31.250` (/24)   |
| `SPEXREGISTER_GRAPHQL_URL`        | Spexregister's GraphQL endpoint on the shared network                        |
| `SPEXFLIX_GRAPHQL_URL`, `SPEXFLIX_WEB_URL` | Spexflix, for links between tracks and videos; empty without Spexflix; also the application switcher |
| `SPEXREGISTER_WEB_URL`            | Spexregister's web, for links to a spex; also the application switcher       |
| `FGV_REVIVAL_WEB_URL`             | Nyuppsättning's web, for the application switcher                            |
| `API_IMPORT_SAMPLE_DATA`          | `true` on staging only: replaces all data at every start                     |
| `API_SAMPLE_DATA_SIZE`            | `small` or `large`                                                           |
| `SUPPORT_EMAIL`, `FEEDBACK_EMAIL` | Shown on the Support and About pages                                         |
| `UMAMI_WEBSITE_ID`                | Umami website for `WEB_HOST`; without it the web sends no statistics         |

For visitor statistics, run `bin/configure-umami.sh` in `fgv-infra-deploy` (see *Umami* in its README). It adds a
website `SPEXIFY_NAME` for `SPEXIFY_WEB_HOST` and prints its ID; put that ID in `UMAMI_WEBSITE_ID`. The web
serves Umami's tracker as `/stats/script.js` and forwards events through `/stats/api/send`, so browsers only talk to
`WEB_HOST`. Leave the ID empty to send nothing.

### Secrets

`API_APP_PASSWORD_ENCRYPTION_KEY` encrypts the users' app passwords. If it is lost, every app password stops working
and users must create new ones; `bin/backup-media.sh` backs it up.

## Media

Everything lies under `data/media/`, mounted into the API; Navidrome mounts only `data/media/music` and only reads it:

| Folder         | Content                                  |
|----------------|------------------------------------------|
| `music/`       | Published tracks and their covers        |
| `unpublished/` | Unpublished tracks                       |
| `trash/`       | Trashed tracks, until an admin empties the trash |
| `covers/`      | Every album's cover                      |
| `uploads/`     | Unfinished uploads, deleted after 24 hours |

## First start

The API creates its tables, and on staging (`API_IMPORT_SAMPLE_DATA=true`) replaces all data with sample data built on
Spexregister's sample spex; see *Sample data* in `fgv-spexify-server`'s README for the users and the app password.
Spexregister deletes all Keycloak users on every start of its sample import, so restart Spexify after it:
`docker compose restart spexify-api`. The sample import keeps Navidrome's database (stars and playlists); run
`bin/reset-navidrome.sh` to empty it.

## Production

- `.env` from `production.env.example`: `DEPLOY_ENV=production` (the API then refuses sample data),
  `API_IMPORT_SAMPLE_DATA=false`, and images pinned to release versions.
- No Cloudflare. `WEB_HOST` is served by production's reverse proxy, with the routes of `fgv-infra-deploy`'s *Edge
  proxy*: `/rest/*` to `spexify-api:8080`, everything else to `spexify-web:3000`, without buffering streams.
- `bin/backup-db.sh` and `bin/backup-media.sh` in cron, with `backups/` copied off the host.
- The music from the old Subsonic server is moved in once with `fgv-spexify-migration` before `spexify.fgv.nu` is
  pointed at this host.

## Troubleshooting

| Symptom                                           | Cause                                                                       |
|---------------------------------------------------|-----------------------------------------------------------------------------|
| Apps say "wrong username or password"             | Use the username shown on *My apps* and an app password, not the FGV password |
| *Music server* says "not answering"               | `spexify-navidrome` is down, or `NAVIDROME_SUBNET_PREFIX` changed without recreating the network |
| Published tracks missing in apps                  | Navidrome has not scanned yet; *Administration → Music server → Scan again* |
| Login fails with "Invalid parameter: redirect_uri" | `SPEXIFY_WEB_HOST` in `fgv-infra-deploy` doesn't match `WEB_HOST`          |

[1]: https://github.com/bloomper/spexregister-deploy
[2]: https://github.com/bloomper/fgv-infra-deploy
