# Spexify Deploy

Docker Compose setup for running Spexify (server, web, MySQL and Navidrome) on a single host, next to
[spexregister-deploy][1] and [fgv-infra-deploy][2], which runs Keycloak and the shared network `fgv-<DEPLOY_ENV>`.

Cloudflare and Tailscale are used on staging only. Production uses neither: its own reverse proxy serves `WEB_HOST`
and `API_HOST` (see *Production*).

```
Staging:
Browser ──https──▶ Cloudflare ──tunnel──▶ cloudflared ──▶ spexify-web:3000              (WEB_HOST)
Browser, Subsonic apps ──https──▶ Tailscale Funnel ──▶ tailnet-spexify-api (fgv-infra-deploy) ──▶ spexify-api:8080   (API_HOST)

spexify-web ──▶ spexify-api ──▶ spexify-mysql
                spexify-api ──Remote-User──▶ spexify-navidrome:4533   (network "navidrome", internal)
                spexify-api ──▶ keycloak-server, spexregister-api, spexflix-api   (fgv network)
```

- On staging, the web goes through the Cloudflare Tunnel like Spexregister, behind Cloudflare Access. Uploads are tus
  chunks of at most 50 MB through the web, below the request limit of Cloudflare's free plan.
- Audio doesn't go through Cloudflare, whose CDN terms restrict serving audio and large files on the free plans.
  Staging's host isn't reachable from the internet, so `API_HOST` is `spexify-api-staging.<tailnet>.ts.net`, published
  with Tailscale Funnel and proxied to `spexify-api` (`compose.tailnet.yaml` in `fgv-infra-deploy`, see its
  *Tailnet*). Listeners and Subsonic apps need no Tailscale. On production, `API_HOST` is served from the host.
  It serves:
  - the Subsonic API (`/rest/*`) for apps, which connect to `API_HOST`;
  - the web player's audio and the downloads, from signed, expiring links (`/media/*`): the web checks the user's
    session, asks the API for a link and redirects the browser to it, so the browser never holds a token;
  - the API documentation (`/docs`), and GraphQL, which requires a Keycloak token.

Navidrome is reachable only from the API, on an internal network where the API has a fixed address
(`NAVIDROME_SUBNET_PREFIX.10`), and it trusts the `Remote-User` header only from that address. It has no published
port and no route to the internet.

## Files

| File                     | Purpose                                                                          |
|--------------------------|----------------------------------------------------------------------------------|
| `compose.yaml`           | `spexify-mysql`, `spexify-navidrome`, `spexify-api`, `spexify-web`               |
| `compose.tunnel.yaml`    | `cloudflared` connector for `WEB_HOST`, staging only                             |
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
  On staging, its tailnet containers (`compose.tailnet.yaml`) must run; on production, its edge proxy
  (`compose.edge.yaml`, whose `.env` names `API_HOST` as `SPEXIFY_API_HOST`) or production's own reverse proxy.
- `spexregister-deploy` running a `spexregister-server` release that knows the `MEDIA` role.

## 2. Cloudflare (staging only)

Only staging uses Cloudflare. On production, skip this section and point `WEB_HOST` and `API_HOST` at production's
reverse proxy (see *Production*).

1. Create a tunnel (Networking → Tunnels → *Create a tunnel* → Cloudflared), e.g. `fgv-spexify-staging`, and copy its
   token.
2. Add one published application: `WEB_HOST` → `http://spexify-web:3000`.
3. Restrict `WEB_HOST` to testers with Cloudflare Access, as `spexregister-deploy`'s README describes.

`API_HOST` is not on Cloudflare: it is the Funnel name of `tailnet-spexify-api`, e.g.
`spexify-api-staging.tail1234.ts.net` (see *Tailnet* in `fgv-infra-deploy`). It is public and has no Access, like
Spexregister's API: Subsonic apps can't complete an Access login, the API requires a Keycloak token or an app password,
and its media links are signed and expire.

## 3. Checkout and configuration

```shell
git clone https://github.com/bloomper/fgv-spexify-deploy.git
cd fgv-spexify-deploy

cp staging.env.example .env          # set the hostnames
bin/init-secrets.sh                  # copies the client secrets from ../fgv-infra-deploy
nano secrets/cloudflared.env         # staging only: TUNNEL_TOKEN=<token from step 2>
mkdir -p data/api/log_data data/media/music data/navidrome
sudo chown -R 1000:1000 data
docker compose up -d
```

| Variable                          | Purpose                                                                      |
|-----------------------------------|------------------------------------------------------------------------------|
| `WEB_HOST`                        | Spexify's web                                                                |
| `API_HOST`                        | The API's DNS-only address: Subsonic apps, audio, downloads and `/docs`      |
| `KEYCLOAK_HOST`, `KEYCLOAK_REALM` | Keycloak's public address and realm                                          |
| `NAVIDROME_SUBNET_PREFIX`         | The internal network between the API and Navidrome, e.g. `172.31.250` (/24)   |
| `SPEXREGISTER_GRAPHQL_URL`        | Spexregister's GraphQL endpoint on the shared network                        |
| `SPEXFLIX_GRAPHQL_URL`, `SPEXFLIX_WEB_URL` | Spexflix, for links between tracks and videos; empty without Spexflix; also the application switcher |
| `SPEXREGISTER_WEB_URL`            | Spexregister's web, for links to a spex; also the application switcher       |
| `FGV_REVIVAL_WEB_URL`             | Nyuppsättning's web, for the application switcher                            |
| `SPEXGRAM_WEB_URL`, `ARCHIVE_WEB_URL` | Spexgram's and Spexarkivet's webs, for the application switcher         |
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

`API_MEDIA_SIGNING_KEY` signs the links to audio and downloads. Changing it invalidates every link handed out, which
only makes open players ask for new ones.

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
- No Cloudflare: `COMPOSE_FILE` leaves out `compose.tunnel.yaml` and needs no `secrets/cloudflared.env`. Production's
  own reverse proxy terminates TLS and forwards `WEB_HOST` to `spexify-web:3000` (tus chunks of up to 50 MB) and
  `API_HOST` to `spexify-api:8080`, without buffering streams, as `fgv-infra-deploy`'s *Edge proxy* describes.
- `bin/backup-db.sh` and `bin/backup-media.sh` in cron, with `backups/` copied off the host.
- The music from the old Subsonic server is moved in once with `fgv-spexify-migration` before `spexify.fgv.nu` is
  pointed at this host. Subsonic apps then connect to `API_HOST`, not `spexify.fgv.nu`.

## Troubleshooting

| Symptom                                           | Cause                                                                       |
|---------------------------------------------------|-----------------------------------------------------------------------------|
| Apps say "wrong username or password"             | Use the username shown on *My apps* and an app password, not the FGV password |
| *Music server* says "not answering"               | `spexify-navidrome` is down, or `NAVIDROME_SUBNET_PREFIX` changed without recreating the network |
| Published tracks missing in apps                  | Navidrome has not scanned yet; *Administration → Music server → Scan again* |
| Login fails with "Invalid parameter: redirect_uri" | `SPEXIFY_WEB_HOST` in `fgv-infra-deploy` doesn't match `WEB_HOST`          |
| Tracks don't play; the console names a Content Security Policy | `API_HOST` changed without restarting `spexify-web`          |
| Apps or the player can't reach `API_HOST` (staging) | `tailnet-spexify-api` isn't running or logged in (see its log), or Funnel isn't allowed for `tag:fgv-staging` |
| Apps or the player can't reach `API_HOST` (production) | `SPEXIFY_API_HOST` in `fgv-infra-deploy` doesn't match `API_HOST`, or `edge-caddy` isn't running |

[1]: https://github.com/bloomper/spexregister-deploy
[2]: https://github.com/bloomper/fgv-infra-deploy
