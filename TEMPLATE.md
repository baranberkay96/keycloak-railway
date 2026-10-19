# Keycloak 26 Identity and SSO Server — Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Keycloak 26 Identity and SSO Server** (major version 26 = current release line, 26.8.1) |
| Description | Single sign-on, OAuth2/OIDC and SAML for your apps, backed by Postgres. (71 chars, as given) |
| Category | Authentication |
| Tags | keycloak, sso, oidc, oauth2, saml, identity, iam, postgres |
| Icon | `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/keycloak.svg` (HTTP 200, image/svg+xml) |
| User input at deploy | None. The admin password is generated; the admin username defaults to `admin`. |
| Repo for repo-based services | `baranberkay96/keycloak-railway`, service `Keycloak` → root directory `/services/keycloak` |

## Base market template

| Market template | Active projects | Setup | Verdict |
|---|---|---|---|
| `mSwigX` "Keycloak" (leader) | 258 | Repo `leonardochappuis/keycloak-docker`: optimized build of **Keycloak 25.0.6**, Keywind theme, Apple + Discord IdP jars, custom JDBC_PING provider for replicas, `postgres-ssl:latest` | Base for the shape (optimized repo build + Railway Postgres). Outdated major, deprecated `KEYCLOAK_ADMIN*` variables, removed `KC_PROXY=edge`, healthcheck on a static admin resource path instead of readiness, admin username is a required input, no JVM sizing, Postgres TCP-proxy variables. No license → read only. |
| `keycloak` "Keycloak Identity Management…" | 44 | `quay.io/keycloak/keycloak:latest`, `kc.sh start` (re-augments on every boot) | Floating tag, `KC_HOSTNAME_STRICT=false` (URLs from request headers), admin username/password left empty (no admin is created → locked out), health enabled but no healthcheck, public Postgres URL. Nothing taken. |
| `keycloak-1` "Keycloak" | 2 | Repo `INAPP-Mobile/keycloak` + `postgres:16-alpine` | Hard-coded DB password `keycloak_pw_2026`, removed `KC_PROXY`, hard-coded `postgres.railway.internal`, no healthcheck. Nothing taken. |

## Pinned versions

| Service | Image / source | Tag | Release date | Checked |
|---|---|---|---|---|
| Keycloak | `services/keycloak` → `FROM quay.io/keycloak/keycloak` | `26.8.1` (manifest list `sha256:79c623a2…`, amd64/arm64/ppc64le; same digest as `26.8` and `latest`) | 2026-10-13 | 2026-10-20 |
| Postgres | `ghcr.io/railwayapp-templates/postgres-ssl` | `18` (Railway base; Keycloak 26.8 supports and tests PostgreSQL 18) | Railway base | 2026-10-20 |

The image ships OpenJDK 21.0.12 on UBI 9 micro (read from the registry's layer list).

## Architecture

```
Browser / apps ──HTTPS──▶ Railway edge (TLS, X-Forwarded-*) ──HTTP──▶ Keycloak :8080 on [::]  (public domain)
                                                                       │  /realms, /admin, /resources, /health/*
                                                                       │  :9000 /metrics (private only)
Apps in the project ──http://keycloak.railway.internal:8080──────────▶ ┘  (backchannel: tokens, JWKS, introspection)
                                                                       │
                                                                       └─▶ Postgres 18 (realms, users, clients, persistent sessions; volume)
```

## Design decisions

### Optimized build (`services/keycloak/Dockerfile`)

Two stages as in Keycloak's container guide: the builder runs `kc.sh build` with `KC_DB=postgres`, `KC_HEALTH_ENABLED=true`, `KC_METRICS_ENABLED=true` and `KC_HTTP_MANAGEMENT_HEALTH_ENABLED=false`; the final stage copies `/opt/keycloak` into a clean `26.8.1` image and starts `start --optimized`, so no re-augmentation happens on boot. Every build option is a Docker `ARG`, and Railway passes a service variable with the same name as a build argument. That is why `KEYCLOAK_VERSION` (global ARG used in both `FROM` lines) and `KC_DB` are service variables. `KC_FEATURES` / `KC_FEATURES_DISABLED` can be added as service variables the same way; empty values are unset before `kc.sh build`.

No provider jars are added, so the provider-mtime problem with `--optimized` (upstream "Known issues with Docker") does not apply.

### Healthcheck on the port in `PORT`

Keycloak 26 serves `/health/*` on the management port 9000 by default, while Railway's healthcheck probes the port in `PORT` (Rule 8.1). Keycloak 26.8 has a supported build option for exactly this: `http-management-health-enabled=false` moves the health endpoints to the main HTTP port (`ManagementOptions.java`: "If false, health endpoints will be exposed on the main interface"). `/metrics` keeps the management interface on, so port 9000 stays open for metrics on the private network only (no domain points to it).

- Healthcheck: `GET /health/ready` on 8080, timeout 900 s. With health enabled, Keycloak's async bootstrap opens the port early and `/health/ready` returns 503 until the database schema is migrated and the server is initialized, then 200.
- Trade-off: `/health`, `/health/live`, `/health/ready` and `/health/started` answer on the public domain. They return only UP/DOWN per check (no data, no write access). Keycloak's reverse-proxy guide recommends hiding them; Railway cannot filter paths at the edge.
- Alternative kept out on purpose: `PORT=9000` with the domain's target port 8080 would keep health private, but if the domain ever followed `PORT`, the login UI would disappear and `/metrics` would become public. The chosen layout uses one port for domain and healthcheck, the standard Railway setup.

### JVM sized from the container, not the host (Rule 8.15)

`kc.sh` (26.8.1) uses `-XX:MaxRAMPercentage=70 -XX:MinRAMPercentage=70 -XX:InitialRAMPercentage=50` when `KC_RUN_IN_CONTAINER=true` and `JAVA_OPTS_KC_HEAP` is unset. The JVM applies those to whatever memory it sees: the cgroup limit if there is one, otherwise host RAM. On a Railway service whose limit is the plan maximum (tens of GB), that is a heap of many GB with half of it committed at start; upstream's container guide itself warns that without a limit "the memory consumption rapidly increases" and is returned to the OS reluctantly. CPU-derived pools (G1 threads, Vert.x event loops, `http-pool-max-threads` = max(50, 4 × CPUs)) scale with the visible cores in the same way.

`railway-entrypoint.sh` therefore sets `JAVA_OPTS_KC_HEAP` itself (kc.sh appends it to its own defaults: G1, `ExitOnOutOfMemoryError`, metaspace limits):

- limit = cgroup v2 `memory.max` (or v1 `memory.limit_in_bytes`); ≥ 1 TiB or `max` counts as no limit.
- `-Xmx` = min(`JVM_HEAP_MAX_MB` = 1024, limit × `JVM_HEAP_PERCENT` (70) %, limit − 384 MB), at least 256 MB. Keycloak's sizing guide measures about 300 MB of non-heap memory; 1250 MB in total covers realms plus 10,000 cached sessions.
- `-Xms` = a quarter of `-Xmx`; `-XX:MinHeapFreeRatio=20 -XX:MaxHeapFreeRatio=40 -XX:G1PeriodicGCInterval=300000` let an idle server give heap back to the OS.
- `-XX:ActiveProcessorCount` = min(cgroup CPU quota (or `nproc`), `JVM_MAX_CPUS` = 4).
- `MALLOC_ARENA_MAX=2` limits glibc arena growth on many-core hosts.
- Setting `JAVA_OPTS` or `JAVA_OPTS_KC_HEAP` on the service disables all of this (kc.sh then uses the user's value).

Results of the sizing logic (tested with fake cgroup files, see report): 1 GiB/2 CPU → `-Xms160m -Xmx640m`, 2 CPUs; 2 GiB → 1024 MB heap; 48 GiB/48 CPU → 1024 MB heap, 4 CPUs; no limit → 1024 MB heap, 4 CPUs.

### Database wait instead of a pre-deploy step

Keycloak has no separate migration command; Liquibase migrations run inside server start-up under a database lock, with `/health/ready` DOWN until they finish. So there is no `preDeployCommand` (Rule 8.6 does not map onto Keycloak); instead:

- The entrypoint waits up to `DB_WAIT_SECONDS` (600) for a TCP connection to `KC_DB_URL_HOST:KC_DB_URL_PORT` (or the host in `KC_DB_URL`), using bash `/dev/tcp` with a 5 s `timeout` per probe. After the limit it starts Keycloak anyway.
- Restart policy `ALWAYS` (no max retries) and a 900 s healthcheck window cover a Postgres that is still being created when the repo build finishes (Rule 8.5).

### Hostname and proxy

- `KC_HOSTNAME=https://${{RAILWAY_PUBLIC_DOMAIN}}` (full URL, hostname v2; `hostname-strict` stays at its default `true`, so URLs never come from request headers).
- `KC_PROXY_HEADERS=xforwarded` (the removed `KC_PROXY=edge` of older templates is not used), `KC_HTTP_ENABLED=true`, `KC_HTTP_PORT=${{PORT}}`.
- `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`: apps in the project can use `http://keycloak.railway.internal:8080` for back-channel calls; the issuer and browser URLs stay on the public domain. Set it to `false` for strictly fixed URLs.
- `KC_HTTP_HOST=::`: Java binds dual-stack, so callers reach Keycloak over IPv4 or IPv6 (Rule 8.14). The management port inherits it.

### Admin bootstrap (no open setup page)

`KC_BOOTSTRAP_ADMIN_USERNAME=admin` and `KC_BOOTSTRAP_ADMIN_PASSWORD=${{secret(32)}}` create a temporary admin in the master realm when the master realm is first created (`ApplianceBootstrap.java`; the expiration option is hidden and not applied in 26.8.1). The welcome page's "create admin" form only appears when no admin exists, so it never shows. Changing these variables later has no effect; recovery uses `kc.sh bootstrap-admin` (see Open questions).

### Cache mode

`KC_CACHE=local` (runtime option in 26.8, no rebuild needed). With one replica there is nothing to cluster, and it avoids JGroups trying to join the previous deployment during Railway's zero-downtime overlap. Persistent user sessions (default since 26.0) and login failures (26.8) live in Postgres, so a restart keeps users signed in. Keycloak's guide describes `local` as meant for single-node/dev use; here it is the single-node production mode, and the scaling path below switches to `ispn`.

## Services

All services are created together; references resolve at deploy time.

### Keycloak

- **Source:** repo `baranberkay96/keycloak-railway`, root directory `/services/keycloak` (Dockerfile build, `FROM quay.io/keycloak/keycloak:26.8.1`)
- **Start command:** image default (`railway-entrypoint.sh start --optimized`)
- **Pre-deploy command:** none (Keycloak migrates at start-up, see above)
- **Healthcheck:** `/health/ready` (timeout 900 s)
- **Public domain:** yes → target port `8080`
- **TCP proxy:** none
- **Volume:** none (all state in Postgres; this also keeps replicas possible)
- **Restart policy:** ALWAYS
- **Replicas:** 1

| Variable | Value | Description |
|---|---|---|
| `PORT` | `8080` | Port Keycloak's HTTP listener uses; Railway routes the public domain and its healthcheck here. |
| `KEYCLOAK_VERSION` | `26.8.1` | quay.io/keycloak/keycloak tag the image is built from (build argument). Change it to upgrade; back up Postgres first. |
| `KC_HOSTNAME` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | Public base URL used in tokens (issuer) and redirects. Change it when you add a custom domain. |
| `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` | `true` | Lets apps in this project call Keycloak over the private network (http://keycloak.railway.internal:8080) for token, JWKS and introspection requests. |
| `KC_PROXY_HEADERS` | `xforwarded` | Trust X-Forwarded-* headers from Railway's edge proxy, which terminates TLS. |
| `KC_HTTP_ENABLED` | `true` | Plain HTTP listener behind Railway's TLS-terminating edge. |
| `KC_HTTP_PORT` | `${{PORT}}` | HTTP port, kept equal to PORT. |
| `KC_HTTP_HOST` | `::` | Bind address. :: is dual-stack (IPv4 and IPv6), so private-network callers reach Keycloak in every Railway environment. |
| `KC_DB` | `postgres` | Database vendor. Build-time option, baked into the optimized image; keep it postgres. |
| `KC_DB_URL_HOST` | `${{Postgres.PGHOST}}` | Postgres host on the private network. |
| `KC_DB_URL_PORT` | `${{Postgres.PGPORT}}` | Postgres port. |
| `KC_DB_URL_DATABASE` | `${{Postgres.PGDATABASE}}` | Postgres database name. |
| `KC_DB_USERNAME` | `${{Postgres.PGUSER}}` | Postgres user. |
| `KC_DB_PASSWORD` | `${{Postgres.PGPASSWORD}}` | Postgres password (generated on the Postgres service). |
| `KC_DB_POOL_MAX_SIZE` | `20` | Maximum database connections per Keycloak replica (upstream default 100; Postgres allows 100 in total). |
| `KC_BOOTSTRAP_ADMIN_USERNAME` | `admin` | Username of the temporary admin created in the master realm on first start. Changing it later has no effect. |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | `${{secret(32)}}` | Password of that temporary admin (generated). Sign in with it, create a permanent admin, then delete the temporary one. |
| `KC_CACHE` | `local` | local = single-node caches (one replica). Set ispn before raising replicas so nodes form a JGroups cluster via the database (jdbc-ping). |
| `KC_LOG_LEVEL` | `info` | Root log level (e.g. info, debug, or info,org.keycloak.events:debug). |
| `JVM_HEAP_MAX_MB` | `1024` | Upper bound for the JVM heap in MB. The entrypoint uses the smaller of this, 70% of the container memory limit, and the limit minus 384 MB. |
| `JVM_HEAP_PERCENT` | `70` | Share of the container memory limit the heap may use (Keycloak's own default ratio), capped by JVM_HEAP_MAX_MB. |
| `JVM_MAX_CPUS` | `4` | CPU count reported to the JVM (sizes GC and HTTP thread pools). Lowered automatically if the container has a smaller CPU quota. |
| `DB_WAIT_SECONDS` | `600` | How long the entrypoint waits for Postgres to accept connections before starting Keycloak (0 = do not wait). |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `30` | Time between SIGTERM and SIGKILL on redeploys so Keycloak can shut down cleanly. |

Build-time defaults in the Dockerfile (not service variables): `KC_HEALTH_ENABLED=true`, `KC_METRICS_ENABLED=true`, `KC_HTTP_MANAGEMENT_HEALTH_ENABLED=false`. Overriding them as service variables rebuilds with the new value; if health goes back to port 9000, set `PORT=9000` too or the healthcheck fails.

### Postgres

Copied unchanged from `templates/_railway-base/postgres.json`.

- **Source:** Docker image `ghcr.io/railwayapp-templates/postgres-ssl:18`
- **Start command:** image default
- **Healthcheck:** none
- **Public domain:** no (private network only)
- **TCP proxy:** none
- **Volume:** `/var/lib/postgresql/data`
- **Restart policy:** ON_FAILURE (max 10 retries)
- **Replicas:** 1

| Variable | Value | Description |
|---|---|---|
| `PGDATA` | `/var/lib/postgresql/data/pgdata` | Location where the database will be initialized. |
| `PGHOST` | `${{RAILWAY_PRIVATE_DOMAIN}}` | Railway Private Domain Name. |
| `PGPORT` | `5432` | Port to connect to Postgres. |
| `PGUSER` | `${{ POSTGRES_USER }}` | Required variable for Data panel. |
| `PGDATABASE` | `${{POSTGRES_DB}}` | Required variable for the data panel. |
| `PGPASSWORD` | `${{POSTGRES_PASSWORD}}` | Required variable for Data panel. |
| `POSTGRES_DB` | `railway` | Default database created when image is started. |
| `DATABASE_URL` | `postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{PGDATABASE}}` | URL to connect to Postgres database. |
| `POSTGRES_USER` | `postgres` | User to connect to Postgres DB. |
| `SSL_CERT_DAYS` | `820` | SSL certificate expiry in days. |
| `POSTGRES_PASSWORD` | `${{ secret(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") }}` | Password to connect to DB. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` | Allow Postgres to cleanly shut down. |

## Improvements over market templates

| # | Change | Why |
|---|---|---|
| 1 | Keycloak 26.8.1 pinned (leader: 25.0.6, `keycloak`: `latest`) | Current supported release, reproducible builds; one variable to upgrade. |
| 2 | Optimized build with Postgres, health and metrics; `start --optimized` | Faster, deterministic start (the 44-project template re-augments on every boot). |
| 3 | Real readiness healthcheck `/health/ready` on the `PORT` port via `http-management-health-enabled=false` | The leader probes a static admin resource; the others have no healthcheck. Railway now only routes to a migrated, initialized server. |
| 4 | JVM heap and CPU count from the cgroup limits, with caps and overrides | Upstream defaults take 70 % of whatever memory is visible; avoids multi-GB heaps and host-sized thread pools on Railway. |
| 5 | Keycloak 26 variables only: `KC_BOOTSTRAP_ADMIN_*` with a generated password and default username, `KC_PROXY_HEADERS=xforwarded`, full-URL `KC_HOSTNAME` with strict hostname | Replaces removed/deprecated `KEYCLOAK_ADMIN*` and `KC_PROXY`; no empty admin password, no header-derived URLs, no required input. |
| 6 | Database wait in the entrypoint, restart `ALWAYS`, 900 s healthcheck window | Cold project starts no longer depend on Postgres being up before the build finishes. |
| 7 | Private back-channel URL and dual-stack listener | Apps in the project talk to Keycloak over `keycloak.railway.internal` in IPv4 and IPv6 environments. |
| 8 | Railway base Postgres 18 (`postgres-ssl:18`), no TCP proxy variables, pool capped at 20 | Supported PostgreSQL version, no public database endpoint, headroom for replicas and tools. |
| 9 | Documented single-node cache plus a scaling path (`KC_CACHE=ispn`, jdbc-ping, IPv6 bind address set by the entrypoint) using Keycloak 26's built-in JDBC_PING2 | The leader needs a custom compiled JDBC_PING provider (Keycloak 25); 26.x ships `jdbc-ping` as the default stack. |
| 10 | Graceful shutdown window (`RAILWAY_DEPLOYMENT_DRAINING_SECONDS=30`) | Keycloak's shutdown delay (1 s) and timeout (10 s) fit inside it. |

Not carried over from the leader: the Keywind theme and Apple/Discord identity-provider jars (third-party extensions, not part of Keycloak; users can fork the repo and add jars to `/opt/keycloak/providers` before `kc.sh build`), `token-exchange` preview feature (standard token exchange V2, internal-to-internal, is supported by default since 26.2; the legacy V1 preview can still be enabled with `KC_FEATURES=token-exchange`).

## First login

1. Wait for the Keycloak deployment to turn healthy. The first start creates the schema; the log shows `Created temporary admin user with username admin` and then the started message.
2. Open `https://{your-domain}/admin`, sign in with `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD` (Keycloak service → Variables).
3. Master realm → Users → Add user; set a password (Credentials); Role mapping → assign `admin`. Sign out, sign in as the new user, delete the temporary admin (the console shows a banner until you do).
4. Master realm → Realm settings → Security defenses → Brute force detection on; Authentication → require OTP for administrators.
5. Create a realm for your applications and add clients (OIDC or SAML) there.

## E-mail (Rule 8.11)

Keycloak sends e-mail only over SMTP; there is no built-in HTTP-API sender (checked in 26.x release notes; 26.2 added XOAUTH2 token auth for SMTP, still SMTP). SMTP is configured per realm in the admin console (Realm settings → Email), not through variables. Railway allows outbound SMTP on Pro. On Trial/Hobby, password-reset, verify-e-mail and invitation e-mails fail; admins can still set passwords and required actions manually. A relay on a non-standard port (for example 2525) may work but is untested.

## Scaling

- **Vertical:** raise the service's memory and `JVM_HEAP_MAX_MB` together (heap ≈ 70 % of the memory you want Keycloak to use), and `JVM_MAX_CPUS` for login-heavy workloads (upstream: about 15 password logins per second per vCPU).
- **Horizontal (advanced, unverified on Railway):**
  1. Set `KC_CACHE=ispn` and deploy with one replica. The entrypoint binds JGroups (`cache-embedded-network-bind-address`) to the replica's global IPv6 address on `railnet0`, because Railway routes traffic between replicas over the private IPv6 network. Discovery uses the default `jdbc-ping` stack (JDBC_PING2 table in Postgres); JGroups traffic is mTLS-encrypted by default (ports 7800 and 57800).
  2. Raise replicas to 2 or 3. The healthcheck includes the cluster check; logs show the cluster view with all members.
  3. Keep `KC_DB_POOL_MAX_SIZE` × replicas under 100 (Postgres `max_connections`).
  Never run more than one replica with `KC_CACHE=local`: login flows would break when requests land on a different node, and cache invalidation would not propagate.
- **Postgres:** scale vertically (raise the service's resources). Back it up regularly; it holds every realm, user and session.

## Upgrades

`KEYCLOAK_VERSION` is the single version knob (default `26.8.1`, also the Dockerfile's ARG default). Back up Postgres, change the variable, deploy. Keycloak migrates the schema on start while `/health/ready` is DOWN; Railway keeps the old deployment serving until the new one is healthy. Patch releases within 26.8.x are safe in this overlap. For minor or major upgrades, read the upgrade notes first; during the overlap the old version briefly runs against the migrated schema, so plan the upgrade for a quiet period. When moving to a new major (27), rename the listing.

## Resource estimate

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month. Not measured (no local container run this round); based on Keycloak's sizing guide (≈300 MB non-heap, 1250 MB with 10,000 cached sessions), the heap settings above and typical Postgres idle use.

| Service | Idle RAM | Idle CPU | Typical RAM | Typical CPU |
|---|---|---|---|---|
| Keycloak | 0.6–0.75 GB | 0.02 vCPU | 1.0–1.2 GB | 0.15 vCPU |
| Postgres | 0.08 GB | 0.01 vCPU | 0.25 GB | 0.03 vCPU |
| **Total** | **≈0.8 GB** | **≈0.03 vCPU** | **≈1.35 GB** | **≈0.18 vCPU** |

- **Idle:** ≈ $8 RAM + $0.6 CPU + $0.1 volume ≈ **$9/month**.
- **Typical (a few apps, hundreds of daily logins):** ≈ $13.5 RAM + $3.6 CPU + $0.15 volume ≈ **$17/month**.
- **Peak sizing:** the heap cap bounds Keycloak at about 1.4 GB RSS; three replicas with `ispn` ≈ $45–50/month.
- **Minimum plan:** Hobby. On Trial (1 GB per service) the entrypoint sizes the heap to 640 MB, which should boot but leaves little room.

## Verification checklist

- [ ] Build log: `kc.sh build` prints `Server configuration updated and persisted` (build options from the Dockerfile ARGs: postgres, health, metrics, health on the main port).
- [ ] Deploy log: `[railway-entrypoint] memory limit: … -> heap …; JVM CPUs: …` (records the real Railway cgroup values), `database reachable after …`, then Keycloak's `Listening on: http://…:8080` with the management interface on port 9000, and no warning about build options differing from the persisted ones.
- [ ] Deployment turns healthy on `/health/ready` (`{"status":"UP",…}` including the database check).
- [ ] `https://{your-domain}/realms/master/.well-known/openid-configuration` shows `issuer: https://{your-domain}/realms/master`.
- [ ] Admin console sign-in with the bootstrap credentials; banner about the temporary admin; create a permanent admin and delete the temporary one.
- [ ] From another service in the project: `curl http://keycloak.railway.internal:8080/realms/master/.well-known/openid-configuration` returns a `token_endpoint` on the private host; `curl http://keycloak.railway.internal:9000/metrics` returns Prometheus text; `https://{your-domain}/metrics` returns 404.
- [ ] Redeploy Keycloak: the realm, users and an existing browser session survive (Postgres persistence, persistent sessions).
- [ ] Optional: `KC_CACHE=ispn` with 2 replicas; logs show a two-member cluster view and the healthcheck passes.

## Open questions

- **Not run locally.** No Docker this round; the Dockerfile build, `start --optimized` and the healthcheck are statically checked only. First Railway deploy is the first real run.
- **Railway cgroup values:** whether Railway sets `memory.max` / `cpu.max` to the plan limit or leaves them unlimited is not verified; the entrypoint handles both and logs what it found.
- **`KC_HTTP_HOST=::`:** dual-stack binding through Quarkus/Vert.x is expected (Java on `::` is dual-stack, Rule 8.2), not observed on Railway for Keycloak.
- **Build-argument pass-through:** Railway passes service variables to declared `ARG`s; that a variable change (e.g. `KEYCLOAK_VERSION`) triggers a fresh build rather than reusing the previous image is expected, not verified. Fallback: change the ARG default in the Dockerfile and push.
- **Clustering on Railway:** the IPv6 bind address logic and JGroups ports between replicas are untested. Upstream observation from the leader template suggests IPv4 between replicas does not route.
- **Public `/health` endpoints** are an accepted trade-off (status only). `KC_PROXY_TRUSTED_ADDRESSES` is not set because Railway does not publish its edge IP ranges, so X-Forwarded-For can be forged by clients that reach port 8080 directly from inside the project; it only affects logged IPs and brute-force counters.
- **Admin recovery:** if all admins are lost, recovery needs `kc.sh bootstrap-admin user --optimized` run against the same database with Keycloak stopped (for example a one-off service using this image with the same variables). Not scripted here.
