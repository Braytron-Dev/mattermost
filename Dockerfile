# syntax=docker/dockerfile:1.7
#
# Multi-stage build za Mattermost fork.
# Stage 1 — webapp (React) build
# Stage 2 — server (Go) build
# Stage 3 — minimal runtime
#
# Build kontekst je root repoa. Ne treba ti Mattermost release tarball —
# sve se gradi iz izvora.

############################
# Stage 1: webapp builder  #
############################
FROM node:24-bookworm AS webapp-builder

ENV NODE_OPTIONS="--max-old-space-size=6144" \
    CI=true \
    npm_config_loglevel=warn

WORKDIR /build/webapp

# Kopiramo cijeli webapp folder odjednom — workspaces + patch-package
# ne podnose lijepo selektivno kopiranje.
COPY webapp/ ./

RUN npm ci --include=dev
RUN npm run build

# Provjera da je dist napravljen
RUN test -d /build/webapp/channels/dist || (echo "Webapp dist nije napravljen" && exit 1)


############################
# Stage 2: server builder  #
############################
FROM golang:1.25-bookworm AS server-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        make \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/server

# Kopiramo server izvor. Enterprise dir ne postoji u forku — Makefile
# automatski detektuje to i postavlja BUILD_ENTERPRISE_READY=false.
COPY server/ ./

ENV BUILD_NUMBER=fork \
    BUILD_ENTERPRISE=false \
    GOFLAGS="-buildvcs=false"

# build-linux-amd64 zove setup-go-work pa go build za sve pakete pod ./...
# Output: /build/server/bin/mattermost i /build/server/bin/mmctl
RUN make build-linux-amd64

# Generiši default config.json (server bi ga generisao i sam pri startu,
# ali pre-bake-ujemo da prvi boot bude brži)
RUN mkdir -p /build/runtime/config \
    && OUTPUT_CONFIG=/build/runtime/config/config.json \
       go run ./scripts/config_generator


############################
# Stage 3: runtime image   #
############################
FROM ubuntu:noble

# Sistem paketi koje Mattermost koristi za document preview / OCR-like funkcije
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tzdata \
        mailcap \
        media-types \
        unrtf \
        wv \
        poppler-utils \
        tidy \
    && rm -rf /var/lib/apt/lists/*

ARG PUID=2000
ARG PGID=2000
RUN groupadd --gid ${PGID} mattermost \
    && useradd --uid ${PUID} --gid ${PGID} --create-home --home-dir /mattermost --shell /bin/bash mattermost

# Pravi runtime layout — ovo je struktura koju Mattermost binar očekuje
RUN mkdir -p \
        /mattermost/bin \
        /mattermost/client \
        /mattermost/client/plugins \
        /mattermost/config \
        /mattermost/data \
        /mattermost/fonts \
        /mattermost/i18n \
        /mattermost/logs \
        /mattermost/plugins \
        /mattermost/prepackaged_plugins \
        /mattermost/templates

# Server binari
COPY --from=server-builder --chown=2000:2000 /build/server/bin/mattermost /mattermost/bin/mattermost
COPY --from=server-builder --chown=2000:2000 /build/server/bin/mmctl      /mattermost/bin/mmctl

# Server runtime asset-i
COPY --from=server-builder --chown=2000:2000 /build/server/templates /mattermost/templates
COPY --from=server-builder --chown=2000:2000 /build/server/i18n      /mattermost/i18n
COPY --from=server-builder --chown=2000:2000 /build/server/fonts     /mattermost/fonts
COPY --from=server-builder --chown=2000:2000 /build/runtime/config/config.json /mattermost/config/config.json

# Webapp dist → /mattermost/client
COPY --from=webapp-builder --chown=2000:2000 /build/webapp/channels/dist/ /mattermost/client/

RUN chown -R 2000:2000 /mattermost

USER mattermost
WORKDIR /mattermost

ENV PATH="/mattermost/bin:${PATH}" \
    MM_INSTALL_TYPE="docker" \
    MM_SERVICESETTINGS_ENABLELOCALMODE="true" \
    MM_SERVICESETTINGS_LISTENADDRESS=":8065" \
    MM_FILESETTINGS_DIRECTORY="/mattermost/data/" \
    MM_PLUGINSETTINGS_DIRECTORY="/mattermost/plugins/" \
    MM_PLUGINSETTINGS_CLIENTDIRECTORY="/mattermost/client/plugins/" \
    MM_LOGSETTINGS_FILELOCATION="/mattermost/logs/"

EXPOSE 8065

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:8065/api/v4/system/ping || exit 1

CMD ["/mattermost/bin/mattermost"]
