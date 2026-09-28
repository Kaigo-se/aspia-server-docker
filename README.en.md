# Aspia Server in Docker

[![Publish images](https://github.com/SinitsaDA/aspia-server-docker/actions/workflows/publish.yml/badge.svg)](https://github.com/SinitsaDA/aspia-server-docker/actions/workflows/publish.yml)
[![Image](https://img.shields.io/badge/ghcr.io-aspia--server-blue?logo=docker)](https://github.com/SinitsaDA/aspia-server-docker/pkgs/container/aspia-server)

[Русский](README.md) | **English**

[Aspia](https://aspia.org) is an open source remote access system. This project runs its server side, **Router** and **Relay**, in a single Docker container and **keeps it on the latest release automatically**.

> Unofficial project. Aspia is developed by [Dmitry Chapyshev](https://github.com/dchapyshev/aspia); this repository only packages it for Docker.

## Features

- **Router + Relay in one container.** Ready-made images for every Aspia version at `ghcr.io/sinitsada/aspia-server`.
- **Automatic updates.** The `aspia-updater` container checks for Aspia releases every night. For a new release it:
  1. pulls the image;
  2. backs up the data;
  3. starts the new version;
  4. **rolls back** if the new version does not come up healthy.
- **Health check.** Docker knows whether the Router accepts connections and the Relay is connected to it.
- **Migration from Aspia 2.x.** The 2.x configuration and database are converted automatically on the first start, including data from the [`paprikkafox/aspia-server`](https://hub.docker.com/r/paprikkafox/aspia-server) image.
- **Tested images.** GitHub Actions builds an image within 6 hours of an Aspia release and starts it before publishing. The image is rebuilt weekly with Debian security updates.
- **Local builds** for those who prefer not to use prebuilt images.

## Quick start

Requirements:
- **x86_64** Linux (Aspia ships its server packages for this architecture only);
- Docker 24+ with the Compose plugin;
- a public IP address or port forwarding to this server.

```bash
sudo mkdir -p /opt/aspia && cd /opt/aspia
sudo curl -fsSLO https://raw.githubusercontent.com/SinitsaDA/aspia-server-docker/main/compose.yaml
sudo curl -fsSL -o .env https://raw.githubusercontent.com/SinitsaDA/aspia-server-docker/main/.env.example
sudo nano .env          # set EXTERNAL_IP, ASPIA_DIR and TZ
sudo docker compose up -d
sudo docker compose ps  # aspia-server becomes (healthy) in about a minute
```

**Private images:** if the packages are private, create a classic personal access token with only `read:packages` and run `sudo docker login ghcr.io -u <GitHub login>` on the server once. The updater picks the credentials up from `/root/.docker` (`DOCKER_CONFIG_DIR`).

On a fresh start a new configuration is created with the user **admin** / password **admin** (`docker logs aspia-server`). Connect with Aspia Console 3.x to port **8062** and change the password. Two-factor authentication (TOTP) is mandatory for Router users in 3.x. To reset it for a user, run `docker exec aspia-server aspia_router --reset-otp admin`.

The public key for hosts is in `data/config/host.pub`. Hosts 3.x connect to port **8061**, hosts 2.x to **8060**.

## Ports

Host networking (`network_mode: host`) is used.

| Port | Service | Purpose | Expose |
|---|---|---|---|
| 8060/tcp | Router | Aspia 2.x hosts (2.6.2 and later) | if you have 2.x hosts |
| 8061/tcp | Router | Aspia 3.x hosts | yes |
| 8062/tcp | Router | consoles (clients) | yes |
| 8063/tcp | Router | Relay to Router | no |
| 8065/udp | Router | built-in STUN server | yes |
| 8070/tcp | Relay | console to host traffic | yes |

## Settings (`.env`)

| Variable | Default | Description |
|---|---|---|
| `ASPIA_VERSION` | — | Aspia version, **changed automatically** by the updater |
| `EXTERNAL_IP` | — | public IP or DNS name announced by the Relay |
| `ASPIA_DIR` | — | **absolute path** of the project directory on the host (the updater mounts it at the same path) |
| `COMPOSE_PROJECT_NAME` | `aspia` | Compose project name |
| `TZ` | `UTC` | time zone of the containers |
| `UPDATE_TIME` | `04:00` | daily update check |
| `MIN_AGE_DAYS` | `2` | install a release only when it is this many days old (`0` = right away) |
| `KEEP_BACKUPS` | `10` | backups kept in `backups/` |
| `LOG_RETENTION_DAYS` | `30` | Aspia log files older than this are deleted |
| `SELF_UPDATE` | `1` | update the updater image as well |
| `ASPIA_IMAGE`, `UPDATER_IMAGE` | `ghcr.io/sinitsada/...` | image locations |
| `COMPOSE_FILE` | — | `compose.yaml:compose.build.yaml` to build the images locally |
| `DOCKER_CONFIG_DIR` | `/root/.docker` | host `docker login` credentials (private images) |

Run `docker compose up -d` after changing `.env`.

## Updates

`aspia-updater` runs on start and daily at `UPDATE_TIME`:

1. Takes the latest [Aspia release](https://github.com/dchapyshev/aspia/releases) once it is `MIN_AGE_DAYS` old.
2. Pulls its image while the current version keeps running. A rebuilt image of the same version counts as an update too.
3. Stops the server and backs up `data/config` and `data/database` to `backups/`.
4. Starts the new version and waits up to 3 minutes for `healthy`. **Otherwise it restores the backup and the previous image.**
5. Removes old images, extra backups and old logs, then updates itself.

Manual control:

```bash
docker exec aspia-updater update.sh                                  # check now
docker exec -e MIN_AGE_DAYS=0 aspia-updater update.sh                # install a fresh release right away
docker exec -e DRY_RUN=1 -e MIN_AGE_DAYS=0 aspia-updater update.sh   # only report
docker exec -e FORCE_VERSION=3.0.18 aspia-updater update.sh          # switch to a specific version
docker compose stop updater                                          # disable automatic updates
```

## Migrating from Aspia 2.x

On start, the 3.x server converts 2.x data by itself:
- `router.json` and `relay.json` become `*.conf`, the old files are kept as `*.json.bak`;
- the `router.db3` database keeps its hosts and users;
- the encryption key stays the same, so nothing has to change on the hosts.

**How to bring the data in:**
- **New installation:** before the first start, put `router.json`, `relay.json` and `router.pub` into `data/config/`, and `router.db3` into `data/database/`.
- **From `paprikkafox/aspia-server`:** its `./data/config` and `./data/database` have the same layout. Stop the old container first (same ports), then copy the folders.
- **Into a running installation:** put a `.zip` or `.tar.gz` with the four files into the project directory and run `docker exec aspia-updater import-2x.sh import/aspia.zip`.

**Keep in mind:**
- **Hosts older than 2.6.2 cannot connect** to a 3.x Router (`Invalid peer architecture` in the Router log). Update them.
- **Consoles** must be 3.x and connect to port 8062.

## Synology

See [docs/synology.md](docs/synology.md) (in Russian; the steps follow the Linux quick start using Container Manager).

## Backups

Every update and import stores `data/config` and `data/database` in `backups/*.tar.gz`. To restore:

```bash
docker compose stop server
rm -rf data/config data/database
tar -xzf backups/<archive>.tar.gz
docker compose up -d server
```

## Local build

Set `COMPOSE_FILE=compose.yaml:compose.build.yaml` in `.env` (clone the repository first) and run `docker compose up -d --build`. The updater then builds every new release locally.

## License

[GPL-3.0](LICENSE), same as Aspia. Thanks to [Dmitry Chapyshev](https://github.com/dchapyshev) for Aspia and to [paprikkafox](https://github.com/paprikkafox/aspia-server-docker) for the original Aspia Server Docker image.
