# Canary Docker Quickstart

This directory contains the Undermountain Docker stack. The `dev` profile uses a
published engine image with read-only content mounts. The `prod` profile builds
one immutable image containing the engine and tracked content snapshot.

The quickstart currently starts:

- MariaDB
- Canary server from the published runtime image
- MyAAC from the `slawkens/myaac` `2.x` branch
- `opentibiabr/login-server` for the client login webservice
- Test accounts and characters, when enabled

MyAAC is used only as the website/AAC. The MyAAC login webservice file is
removed from the quickstart image, so clients should use `login-server`.

## Security Scope

The default credentials are for local development, testing, and LAN demos. The
`prod` profile changes content packaging, but does not make default passwords or
published ports safe for the public Internet.

Before using it outside a trusted local network:

- Change all default database and MyAAC admin passwords.
- Disable or remove test accounts by setting `CANARY_TEST_ACCOUNTS=false`.
- Review firewall rules for the published TCP ports.
- Pin image tags instead of relying on rolling `latest` tags.

See the [Undermountain Architecture and Stack Decision](../docs/undermountain-architecture-and-stack.md)
for the boundary between development mounts and the immutable production image.

## Requirements

- Docker with Docker Compose v2
- Network access to pull the published Canary image and build the MyAAC image
- A buildx builder named by `CANARY_BUILDER`; local defaults use the
  resource-limited `limited-builder`, configured with `default-load=true`

For a step-by-step beginner guide, see
[`docs/docker/quickstart-for-beginners.md`](../docs/docker/quickstart-for-beginners.md).

## Start The Server

The guarded launchers use the `dev` profile by default:

```bash
sh ./up.sh
```

`COMPOSE_PROFILES=dev` in `docker/.env` also makes the direct command start the
complete development stack instead of only the shared database and login service:

```bash
docker compose up -d --no-build
```

On Windows PowerShell:

```powershell
.\up.ps1
```

To configure `docker/.env` automatically for other PCs on your LAN:

```powershell
.\up.ps1 -Lan
```

To configure `docker/.env` automatically for other PCs on your LAN:

```bash
LAN=true sh ./up.sh
```

These scripts build with `docker compose build --builder "$CANARY_BUILDER"`,
then start with `--no-build`. This prevents Compose from bypassing the configured
resource-limited builder. They also run Compose with `--remove-orphans` and a safe
cleanup. They remove stopped containers and dangling images that belong to this
Compose project, then remove unused Docker build cache older than seven days.
They do not remove Docker volumes, so the MariaDB database and Canary runtime
data are preserved.

The development profile mounts `config.lua`, `data/`, and `data-canary/`
read-only. Changes take effect after restarting `server`, without rebuilding the
engine image. The scripts synchronize `serverName` and `dataPackDirectory` to
`docker/.env` so MyAAC and login-server advertise matching metadata.

## Production Profile

Start an immutable production image on Linux or macOS:

```bash
sh ./up.sh --prod
```

On Windows PowerShell:

```powershell
.\up.ps1 -Prod
```

The `prod` profile builds `docker/Dockerfile.prod`. It packages
`config.lua.dist`, `data/`, `data-canary/`, the database schema, RSA key, seed
scripts, and bootstrap on top of `CANARY_IMAGE`. The resulting
`CANARY_PROD_IMAGE` has no host bind mounts. A content-only build does not compile
C++; a native change first requires a new engine image.

The launchers override `COMPOSE_PROFILES` explicitly, so selecting `prod` does
not also activate the default `dev` services and their conflicting ports.

Docker build cache is Docker-wide, so the start scripts only prune cache older
than seven days. This keeps cleanup data-safe while avoiding aggressive cache
removal that would make every rebuild slow.

Watch the logs:

```bash
docker compose --profile dev logs -f server
docker compose --profile dev logs -f myaac
docker compose --profile dev logs -f login-server
```

Stop the stack:

```bash
docker compose --profile dev down
```

Remove persisted database and server data:

```bash
docker compose --profile dev down -v
```

## Safe Docker Cleanup

Docker can accumulate old build cache and unused layers after repeated builds.
The quickstart start scripts keep this under control without deleting user data:

- `docker container prune --filter label=com.docker.compose.project=otbr`
- `docker image prune --filter label=com.docker.compose.project=otbr`
- `docker builder prune --filter until=168h`

Avoid using `docker system prune -a --volumes` for routine cleanup. It can remove
images, volumes, and data from unrelated Docker projects.

The build-cache cleanup is Docker-wide because Docker does not expose a reliable
Compose-project label for build cache entries. The age filter keeps this safe for
routine quickstart usage.

To start without cleanup:

```powershell
.\up.ps1 -SkipCleanup
```

```bash
SKIP_CLEANUP=true sh ./up.sh
```

To keep a different build cache window, set the age filter:

```powershell
.\up.ps1 -CleanupUntil 72h
```

```bash
CLEANUP_UNTIL=72h sh ./up.sh
```

## Default URLs And Ports

With the default `.env` values:

- MyAAC site: `http://localhost:8080`
- Client login webservice: `http://localhost:8088/login`
- MyAAC admin panel: `http://localhost:8080/admin`
- Login-server HTTP port: `8088`
- Canary login protocol port: `7171`
- Canary game protocol port: `7172`
- Canary status protocol port: `7173`
- Test login: `@test1`
- Test password: `test`
- MyAAC admin login: `myaacadmin`
- MyAAC admin password: `admin123`

The database is only exposed inside the Docker network by default. Add a database
tool profile later, such as Adminer, instead of requiring new users to connect
directly to MariaDB.

## Client Setup

Point the client login webservice to:

```text
http://localhost:8088/login
```

The client login webservice is provided by `opentibiabr/login-server`, not by
MyAAC. MyAAC's own login webservice file is removed from the quickstart image to
avoid accidental use.

The login-server advertises `CANARY_SERVER_IP` and `CANARY_GAME_PORT` to the
current client. Legacy account login uses Canary's login port and advertises the
legacy world port that matches the resolved client profile. For local
quickstart, keep:

```env
CANARY_SERVER_IP=127.0.0.1
CANARY_GAME_PORT=7172
CANARY_LEGACY_1100_GAME_PORT=7174
CANARY_LEGACY_860_GAME_PORT=7175
```

If the client runs on another machine, change `CANARY_SERVER_IP` to the LAN or
public address that the client can reach.

## Environment Contract

The public Docker configuration contract for Canary uses `CANARY_*`.

Do not add new public Canary settings using `MYSQL_*`, `OT_*`, or raw Lua config
variable names. The compose file translates `CANARY_*` into the variables needed
by MariaDB, MyAAC, and login-server.

### Canary Configuration And Content

In `dev`, the repository-root `config.lua` is the runtime source of truth and is
mounted with `data/` and `data-canary/` as read-only content. In `prod`, the
tracked `config.lua.dist` and both content directories are baked into
`CANARY_PROD_IMAGE`.

Docker still overrides the database connection, advertised server IP, and
protocol ports in the runtime copy because those values connect Canary to the
other Compose services and published host ports. `CANARY_CONFIG_FILE` can point
to a different host file; relative paths are resolved from the `docker`
directory in the development profile.

### Database

```env
CANARY_DB_HOST=db
CANARY_DB_PORT=3306
CANARY_DB_NAME=canary
CANARY_DB_USER=canary
CANARY_DB_PASSWORD=canary
CANARY_DB_ROOT_PASSWORD=root
```

`CANARY_DB_HOST` should usually stay as `db` inside Docker Compose. MariaDB runs
on port `3306` inside the Docker network.

### Server Image, Identity, And Ports

```env
CANARY_IMAGE=ghcr.io/opentibiabr/canary:latest
CANARY_PROD_IMAGE=undermountain:prod
CANARY_BUILDER=limited-builder
CANARY_SERVER_NAME=Undermountain
CANARY_SERVER_IP=127.0.0.1
CANARY_SERVER_LOCATION=BRA
CANARY_LOGIN_PORT=7171
CANARY_GAME_PORT=7172
CANARY_LEGACY_1100_GAME_PORT=7174
CANARY_LEGACY_860_GAME_PORT=7175
CANARY_STATUS_PORT=7173
CANARY_STATUS_TIMEOUT=5000
```

`CANARY_IMAGE` is the engine image used directly by `dev` and as the base for
`prod`. `CANARY_PROD_IMAGE` names the final immutable artifact. Pin both to tags
or digests for releases. `CANARY_BUILDER` selects the buildx builder used by the
guarded launchers; local builds must use the resource-limited builder.

The quickstart publishes `CANARY_LOGIN_PORT`, `CANARY_GAME_PORT`,
`CANARY_LEGACY_1100_GAME_PORT`, `CANARY_LEGACY_860_GAME_PORT`, and
`CANARY_STATUS_PORT` to the host using the same port values configured in
`.env`. Keep these values distinct unless you intentionally add a Compose
override for custom port mappings.

`CANARY_SERVER_IP` is the address sent to the client in the world list. It is not
the Docker service name.

### Data Pack And Test Data

```env
CANARY_TEST_ACCOUNTS=true
CANARY_DATA_PACK=data-canary
```

`CANARY_DATA_PACK` supplies matching datapack metadata to MyAAC. Keep it equal
to `dataPackDirectory` in `config.lua`; the guarded start scripts synchronize it
automatically. Canary itself reads the datapack and map settings from
`config.lua`.

Undermountain requires `dataPackDirectory = "data-canary"`,
`toggleDownloadMap = false`, and a versioned `data-canary/world/canary.otbm`.
Startup fails instead of downloading or modifying map content. The empty
`data-canary/world/custom/` directory is versioned because Canary enumerates it
during startup.

When `CANARY_TEST_ACCOUNTS=true`, the container imports:

- `docker/data/01-test_account.sql`
- `docker/data/02-test_account_players.sql`

The default test account password is `test`.
For a first login, use account `@test1` with password `test`.

### MyAAC

```env
MYAAC_HTTP_PORT=8080
MYAAC_SITE_URL=http://localhost:8080
MYAAC_IMAGE=otbr-myaac
MYAAC_REF=2.x
MYAAC_ADMIN_ACCOUNT=myaacadmin
MYAAC_ADMIN_EMAIL=admin@localhost.local
MYAAC_ADMIN_PASSWORD=admin123
MYAAC_ADMIN_PLAYER=ADM1
MYAAC_CLIENT_VERSION=1525
MYAAC_TIMEZONE=America/Fortaleza
```

`MYAAC_REF` is the Git ref used when building the MyAAC image. The default is
`2.x`, which tracks the MyAAC branch compatible with Canary `main`. To test
a tag or another branch, change `MYAAC_REF` and rebuild:

```bash
docker compose --profile dev build --builder limited-builder --no-cache myaac
docker compose --profile dev up -d --no-build
```

The MyAAC container waits until the Canary schema exists, writes its own
`config.local.php`, imports the MyAAC tables, and creates the admin account on
first startup.

The generated MyAAC server path contains the runtime `config.lua` needed for
database and status settings. It does not mount the full Canary datapack into
the web container, and it does not include MyAAC's client login webservice file.

### Login Server

```env
LOGIN_SERVER_IMAGE=opentibiabr/login-server:latest
LOGIN_HTTP_PORT=8088
LOGIN_GRPC_PORT=9090
LOGIN_RATE_LIMITER_RATE=2
LOGIN_RATE_LIMITER_BURST=5
```

These variables belong to `opentibiabr/login-server`, which starts by default.
`LOGIN_SERVER_IMAGE` also defaults to a rolling `latest` tag. Pin this image to a
specific tag or digest when you need reproducible behavior.
With the default ports, the client login URL is:

```text
http://localhost:8088/login
```

## Data Persistence

Docker volumes used by this quickstart:

- `db-volume`: MariaDB data
- `server-data`: Canary database backups and writable runtime state

MyAAC stores its persistent state in the shared Canary database. Its generated
`config.local.php` is recreated from `.env` whenever the container starts.

When an existing Canary schema is detected, the server entrypoint writes a
database backup. With the default `CANARY_DB_NAME=canary`, the backup path is:

```text
/data/canary.sql
```

That path is inside the `server-data` Docker volume.
If `CANARY_DB_NAME` changes, the backup file name follows that database name.

## Runtime Images

The `dev` profile runs `CANARY_IMAGE` with content binds. The `prod` profile
builds `CANARY_PROD_IMAGE` from `docker/Dockerfile.prod`, using `CANARY_IMAGE` as
its engine base. A C++ change must first produce a new engine image through the
maintained native Docker build; a content-only production release rebuilds only
the packaging image.

Local launchers require `CANARY_BUILDER=limited-builder` and split build from
startup so `docker compose up` cannot silently use an unrestricted builder.
Release deployments should pull an immutable `CANARY_PROD_IMAGE` tag and start
with `--no-build`.

The MyAAC image is built locally from `slawkens/myaac` because the quickstart
tracks `MYAAC_REF=2.x` by default. This build installs PHP dependencies with
Composer, but it does not compile Canary.

## CI Coverage

The GitHub Actions job `Docker Quickstart Smoke` runs after `Build - Docker` and
validates the user-facing quickstart with the Docker image produced by the same
CI run whenever the Compose file, quickstart MyAAC image, seed SQL files, or the
smoke workflow changes.

The smoke test runs both profiles from clean databases. It verifies read-only
binds in `dev`, verifies no bind mounts and embedded content in `prod`, checks
MyAAC, and confirms that `opentibiabr/login-server` returns the seeded account.

## Troubleshooting

If the client receives the character list but cannot enter the game, check:

- `CANARY_SERVER_IP` is reachable from the client machine.
- `CANARY_GAME_PORT` is open on the host.
- For 11.00 clients, `CANARY_LEGACY_1100_GAME_PORT` is open on the host.
- For 8.60 clients, `CANARY_LEGACY_860_GAME_PORT` is open on the host.
- The selected Canary service is running: `docker compose --profile dev ps` or
  `docker compose --profile prod ps`.
- The `login-server` container is running in the selected profile.
- The matching `myaac` or `myaac-prod` container is running.
- The server log does not show database connection errors:

```bash
docker compose --profile dev logs server
docker compose --profile dev logs myaac
docker compose --profile dev logs login-server
```

If the server waits for the database, check:

```bash
docker compose --profile dev logs db
docker compose --profile dev ps
```
