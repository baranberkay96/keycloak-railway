# NOTICE — Keycloak 26 Identity and SSO Server

## Software deployed (not redistributed)

| Component | Source | License |
|---|---|---|
| Keycloak | Docker image `quay.io/keycloak/keycloak:26.8.1` (base of `services/keycloak`), source https://github.com/keycloak/keycloak | Apache License 2.0 (image label `org.opencontainers.image.licenses=Apache-2.0`); Copyright Red Hat, Inc. and/or its affiliates and other contributors |
| Red Hat UBI 9 micro, OpenJDK 21 | Layers inside the Keycloak image | UBI EULA / GPLv2 with Classpath Exception (as shipped by upstream) |
| PostgreSQL | Railway base image `ghcr.io/railwayapp-templates/postgres-ssl:18` | PostgreSQL License |

The template builds on the upstream Keycloak image without changing its code. The optimized build only runs `kc.sh build` with build-time options.

## Original files in this package

- `services/keycloak/Dockerfile` — two-stage optimized build. The structure (builder stage running `kc.sh build`, then copying `/opt/keycloak` into a clean image) follows the example in Keycloak's documentation, "Running Keycloak in a container" (`docs/guides/server/containers.adoc`, Apache-2.0). Written for this template.
- `services/keycloak/railway-entrypoint.sh` — JVM sizing from cgroup limits, database wait, JGroups bind address. Written for this template.
- `README.md`, `TEMPLATE.md`, `template.json` — written for this template.

## Upstream files checked (2026-10-20, tag `26.8.1`, via `gh api repos/keycloak/keycloak/contents/...`)

- `quarkus/container/Dockerfile` — ubi9-micro base, `KC_RUN_IN_CONTAINER=true`, user 1000, ports 8080/8443/9000, packages (bash, coreutils, findutils, java-21-openjdk-headless).
- `quarkus/dist/src/main/content/bin/kc.sh` — default `JAVA_OPTS` and `JAVA_OPTS_KC_HEAP` (`-XX:MaxRAMPercentage=70 -XX:MinRAMPercentage=70 -XX:InitialRAMPercentage=50` in containers), `JAVA_OPTS_APPEND`, SIGTERM forwarding to the JVM.
- `quarkus/config-api/src/main/java/org/keycloak/config/ManagementOptions.java` — `http-management-health-enabled` (build time, "If false, health endpoints will be exposed on the main interface"), management port 9000.
- `quarkus/runtime/.../mappers/ManagementPropertyMappers.java` — the management interface stays on for metrics when health moves to the main port.
- `HealthOptions.java`, `MetricsOptions.java`, `CachingOptions.java` (`cache` is a runtime option in 26.8; `cache-stack` defaults to `jdbc-ping`; `cache-embedded-network-bind-address`), `DatabaseOptions.java` (`db-url-host`, `db-pool-max-size` default 100), `HttpOptions.java` (`http-host`, `http-pool-max-threads`, shutdown defaults), `HostnameV2Options.java`, `ProxyOptions.java`, `BootstrapAdminOptions.java`, `ServerOptions.java` (async bootstrap).
- `services/.../managers/ApplianceBootstrap.java` — temporary admin creation; the expiration option is hidden and not applied.
- Docs: `docs/guides/server/containers.adoc`, `management-interface.adoc`, `caching.adoc`, `db.adoc` + `templates/databases.adoc` (PostgreSQL 18.x supported, tested version 18), `hostname.adoc`, `reverseproxy.adoc`, `configuration-production.adoc`, `bootstrap-admin-recovery.adoc`, `docs/guides/observability/health.adoc`, high-availability sizing partials, release notes 26.2–26.8.
- Registry: quay.io tag `26.8.1` (manifest list `sha256:79c623a2…`, linux/amd64 + arm64 + ppc64le, pushed 2026-10-13); file list of the amd64 layers read from the registry to confirm `bash`, `timeout`, `nproc` and JDK 21.0.12 are in the image.

## Reused material

- **Railway base definition** `templates/_railway-base/postgres.json` (this repository): copied as instructed by STANDARD.md, unchanged.
- **Market templates** `mSwigX` (repo `leonardochappuis/keycloak-docker`), `keycloak`, `keycloak-1` (Railway marketplace): reviewed for structure only. The `_upstream/leonardochappuis__keycloak-docker` repository has no license, so no files or text were copied. One idea from reading it is used in our own code: JGroups traffic between Railway replicas needs the replica's IPv6 address on `railnet0`. `railway-entrypoint.sh` implements that independently.
- All prose in this package is original.
