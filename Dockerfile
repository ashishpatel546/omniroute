# syntax=docker/dockerfile:1
# OmniRoute — self-hosted LLM gateway that speaks the OpenAI wire protocol and
# routes to many upstream providers. Built from the npm package: upstream
# publishes no image of its own.
#
#   docker compose up -d --build
#
# Pinned, not "latest": the gateway holds the routing config and the API keys
# its clients authenticate with, so an unattended minor bump is a change to a
# dependency those clients cannot answer a single request without. Bump this
# deliberately.
ARG OMNIROUTE_VERSION=3.8.50

# Node 22, per the package's own engines range (>=22.22.2 <23 || >=24 <27).
FROM node:22-bookworm-slim AS builder
ARG OMNIROUTE_VERSION

# better-sqlite3 ships prebuilds but falls back to compiling from source when
# none matches this exact Node ABI; without a toolchain that fallback fails at
# install time rather than degrading. Build deps stay in this stage only.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# omniroute pulls ~1200 packages. A single ECONNRESET partway through fails the
# whole build, which is what happens on a flaky link with npm's stock 2 retries
# and 5 min timeout — so retry harder and wait longer rather than re-running
# `docker compose build` by hand.
RUN npm config set fetch-retries 5 \
    && npm config set fetch-retry-mintimeout 20000 \
    && npm config set fetch-retry-maxtimeout 180000 \
    && npm config set fetch-timeout 900000 \
    && npm install -g --omit=dev "omniroute@${OMNIROUTE_VERSION}"

FROM node:22-bookworm-slim
ARG OMNIROUTE_VERSION
LABEL org.opencontainers.image.title="omniroute" \
      org.opencontainers.image.version="${OMNIROUTE_VERSION}"

COPY --from=builder /usr/local/lib/node_modules/omniroute /usr/local/lib/node_modules/omniroute
RUN ln -s /usr/local/lib/node_modules/omniroute/bin/omniroute.mjs /usr/local/bin/omniroute

# All persistence — the SQLite store holding upstream provider credentials and
# the gateway API keys — lives here, so this is the one path that must be a
# volume. Overriding DATA_DIR is the package's own documented Docker hook.
ENV DATA_DIR=/data \
    NODE_ENV=production
RUN mkdir -p /data && chown -R node:node /data
VOLUME ["/data"]

USER node
EXPOSE 20128

# Invoked the same way the packaged launcher invokes it, rather than through
# `omniroute serve`: that wrapper manages a background process and a pidfile,
# which is the opposite of what a container wants as PID 1.
CMD ["node", "--dns-result-order=ipv4first", "--max-old-space-size=4096", \
     "/usr/local/lib/node_modules/omniroute/dist/server-ws.mjs"]
