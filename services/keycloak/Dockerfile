# Optimized Keycloak image for Railway.
#
# Stage 1 runs `kc.sh build`, which bakes the build-time options below into
# lib/quarkus so the server can start with `start --optimized` (no
# re-augmentation on every boot). Stage 2 is the clean upstream image plus the
# built server and a small entrypoint (see railway-entrypoint.sh).
#
# Railway passes a service variable as a build argument when its name matches
# an ARG here. Setting KEYCLOAK_VERSION or one of the KC_* build options on the
# service therefore changes the next build without editing this file.

ARG KEYCLOAK_VERSION=26.8.1

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} AS builder

# Build-time options (https://www.keycloak.org/server/all-config, "build" options).
ARG KC_DB=postgres
ARG KC_HEALTH_ENABLED=true
ARG KC_METRICS_ENABLED=true
# Serve /health on the main HTTP port (8080) so Railway's healthcheck, which
# probes the port in PORT, reaches it. /metrics stays on the private
# management port 9000.
ARG KC_HTTP_MANAGEMENT_HEALTH_ENABLED=false
# Optional feature switches, e.g. KC_FEATURES=token-exchange (legacy V1 preview).
ARG KC_FEATURES
ARG KC_FEATURES_DISABLED

WORKDIR /opt/keycloak

# Empty optional ARGs are unset so kc.sh never sees an empty option value.
RUN set -e; \
    if [ -z "${KC_FEATURES:-}" ]; then unset KC_FEATURES; fi; \
    if [ -z "${KC_FEATURES_DISABLED:-}" ]; then unset KC_FEATURES_DISABLED; fi; \
    /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

COPY --from=builder /opt/keycloak/ /opt/keycloak/
COPY --chown=1000:0 --chmod=0755 railway-entrypoint.sh /opt/keycloak/bin/railway-entrypoint.sh

USER 1000

# 8080: HTTP (UI, OIDC/SAML endpoints, admin API, /health). 9000: /metrics (private).
EXPOSE 8080 9000

ENTRYPOINT ["/opt/keycloak/bin/railway-entrypoint.sh"]
CMD ["start", "--optimized"]
