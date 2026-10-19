# Deploy and Host Keycloak with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/keycloak-26-identity-and-sso-server?referralCode=20H68q)

Keycloak is an open-source identity and access management server: single sign-on, OAuth 2.0 / OpenID Connect and SAML 2.0 for your applications, with user federation, social login and multi-factor authentication. This community template runs Keycloak 26 on Railway with Postgres, an optimized server build and a generated admin password.

## About Hosting Keycloak

Keycloak is a Java (Quarkus) server that keeps realms, users, clients and sessions in a relational database. In production it needs a fixed public hostname, TLS in front of it, correct proxy headers, a health endpoint for the platform and a JVM sized to its container. This template builds an optimized image (`kc.sh build` with Postgres, health and metrics), starts it with `start --optimized`, sets the hostname from Railway's public domain, trusts Railway's edge proxy headers, and creates the first admin from a generated password, so no setup page is ever exposed. An entrypoint sizes the heap and CPU count from the container limits instead of the host.

## Common Use Cases

- Single sign-on for internal tools, dashboards and SaaS products over OpenID Connect or SAML
- A self-hosted alternative to hosted identity providers, with users and data in your own Postgres
- Social login (Google, GitHub, Microsoft) and enterprise federation (LDAP, Active Directory, external SAML/OIDC IdPs)
- API protection with OAuth 2.0 access tokens, client credentials and token exchange
- Multi-factor authentication (OTP, WebAuthn and passkeys) in front of existing apps

## Dependencies for Keycloak Hosting

- Keycloak 26.8.1 (`quay.io/keycloak/keycloak:26.8.1`, built into an optimized image)
- PostgreSQL 18 (Railway Postgres, with a volume)
- Optional: an SMTP server for password-reset and verification e-mails (outbound SMTP needs Railway Pro)

### Deployment Dependencies

- Keycloak documentation: https://www.keycloak.org/documentation
- Running Keycloak in a container: https://www.keycloak.org/server/containers
- Configuring a reverse proxy: https://www.keycloak.org/server/reverseproxy
- Configuring the hostname: https://www.keycloak.org/server/hostname
- Health checks: https://www.keycloak.org/observability/health
- Caching and clustering: https://www.keycloak.org/server/caching
- All configuration options: https://www.keycloak.org/server/all-config
- Releases: https://github.com/keycloak/keycloak/releases

### Implementation Details

| Service | Image / source | Role |
|---|---|---|
| Keycloak | `services/keycloak` (FROM `quay.io/keycloak/keycloak:26.8.1`) | Login pages, admin console, OIDC/SAML endpoints and admin API on the public domain (port 8080); `/metrics` on private port 9000 |
| Postgres | `ghcr.io/railwayapp-templates/postgres-ssl:18` | Realms, users, clients, persistent sessions (volume) |

**First login:** wait until the Keycloak deployment is healthy (the first start creates the database schema and takes one to three minutes). Open `https://{your-domain}/admin` and sign in with `KC_BOOTSTRAP_ADMIN_USERNAME` (default `admin`) and the generated `KC_BOOTSTRAP_ADMIN_PASSWORD` from the Keycloak service's Variables tab. Keycloak marks this account as temporary: create a permanent admin in the master realm (Users, then Role mapping: `admin`), sign in with it, delete the temporary one, and turn on OTP and brute-force detection for the master realm. Create a separate realm for your applications.

**Connecting apps:** the issuer is `https://{your-domain}/realms/{realm}`. Apps in the same Railway project can call `http://keycloak.railway.internal:8080/realms/{realm}` for discovery, tokens and keys over the private network; browser redirects always use the public domain.

**Health and metrics:** Railway's healthcheck uses `/health/ready` on port 8080, so the `/health` endpoints answer on the public domain too (status only, no data). Prometheus metrics stay on the private port: `http://keycloak.railway.internal:9000/metrics`.

**Memory:** the entrypoint gives the JVM a heap of at most `JVM_HEAP_MAX_MB` (1024 MB), reduced on smaller containers, and reports at most `JVM_MAX_CPUS` (4) to the JVM. Raise both together with the service's resources for large installations.

**E-mail:** Keycloak sends mail over SMTP only (configured per realm under Realm settings, Email). Railway allows outbound SMTP on the Pro plan. On other plans, password reset and e-mail verification will not work until you upgrade or use a relay that is reachable from Railway.

**Scaling:** the template runs one replica with local caches (`KC_CACHE=local`); sessions are stored in Postgres, so restarts do not log users out. For several replicas, set `KC_CACHE=ispn` first: nodes then discover each other through the database (`jdbc-ping`) and the entrypoint binds the cluster traffic to the private IPv6 address. Never run more than one replica with `KC_CACHE=local`. Keep `KC_DB_POOL_MAX_SIZE` times replicas below Postgres' 100 connections.

**Versions:** the Keycloak version is the `KEYCLOAK_VERSION` variable (default `26.8.1`), used as a build argument. Back up Postgres, change it, and deploy; Keycloak migrates the schema on start. Build options such as `KC_FEATURES` work the same way.

### Why Deploy Keycloak on Railway?

Railway gives Keycloak a TLS-terminated public domain, a private network to your applications and a managed Postgres volume, with usage-based billing. You get a standards-based identity server under your own control without running Kubernetes or managing certificates.
