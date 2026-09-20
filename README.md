# OmniRoute — local LLM gateway

A standalone, always-available LLM gateway for local development. Several
projects use it, none of them own it — so it lives on its own and stays running
in the background.

[OmniRoute](https://github.com/diegosouzapw/OmniRoute) (MIT,
[omniroute.online](https://omniroute.online)) speaks the OpenAI wire protocol
and forwards to one of many upstream providers, so a single endpoint reaches
OpenAI, Gemini, Claude, local models and a set of free tiers. Point any
OpenAI-compatible client at it and switch providers without touching the
client.

This repo is just the packaging: a `Dockerfile` that builds a pinned version of
the upstream npm package (which publishes no image of its own) and a
`docker-compose.yml` that runs it safely on loopback with a persistent volume.

## Run it

```bash
git clone git@github.com:ashishpatel546/omniroute.git
cd omniroute

cp .env.example .env                                    # git-ignored
printf 'STORAGE_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" >> .env

docker compose up -d --build   # first run: pulls ~1200 npm packages, a few minutes
docker compose ps              # omniroute-omniroute-1 ... (healthy)
```

`STORAGE_ENCRYPTION_KEY` encrypts the upstream provider credentials at rest
(AES-256-GCM). Set it **before** the first start and keep it: without that exact
value the existing store cannot be decrypted, and every provider key has to be
added again.

After the first build, `docker compose up -d` is enough. Leave it running —
`restart: unless-stopped` brings it back with Docker.

| | |
|---|---|
| Dashboard | <http://localhost:20128> |
| API base (from the host) | `http://localhost:20128/v1` |
| API base (from another container) | `http://host.docker.internal:20128/v1` |
| Liveness (no auth) | `http://localhost:20128/api/monitoring/health` |

```bash
docker compose logs -f        # follow
docker compose down           # stop, keep providers + keys
docker compose down -v        # stop and WIPE providers + keys
```

## Configuration

Everything server-side lives in `.env` (copied from `.env.example`). Upstream
provider credentials do **not** — see the next section.

| Variable | Default | What it does |
|---|---|---|
| `OMNIROUTE_PUBLISH_PORT` | `20128` | Host port the gateway is published on, loopback-only. |
| `REQUIRE_API_KEY` | `false` | Require `Authorization: Bearer <gateway key>` on `/v1/*`. |
| `ALLOW_API_KEY_REVEAL` | `false` | Let the dashboard re-reveal a minted key's full value. |
| `STORAGE_ENCRYPTION_KEY` | — | AES-256-GCM key for provider credentials at rest. |

## Add an upstream provider

Providers are not env vars — they live encrypted in the gateway's SQLite store
on the `omniroute-data` volume. Add one without putting the key in your shell
history or the process list:

```bash
printf '%s' 'sk-...' | docker compose exec -T omniroute omniroute keys add openai --stdin
docker compose exec omniroute omniroute keys list
```

Or use the dashboard. Then check routing works — `auto` picks a provider for
you:

```bash
curl -s http://localhost:20128/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}'
```

## Security: why the port is loopback-only

OmniRoute's inference plane (`/v1/*`) answers **without an API key** unless
`REQUIRE_API_KEY=true`, and every request it serves is billed to the upstream
providers configured inside it. Its own startup banner warns about this. So the
compose file publishes on `127.0.0.1` rather than `0.0.0.0`: nothing off this
machine can reach it.

If you need it reachable from elsewhere, do both together — set
`REQUIRE_API_KEY=true` in `.env`, mint a gateway key in the dashboard
(Endpoints), and only then widen the binding in `docker-compose.yml`.

One wrinkle regardless of that setting: **`/v1/models` always requires a valid
gateway key.** A client whose health check probes `/v1/models` will report a 401
until you mint a key in the dashboard and give it to that client, even while
chat completions work fine.

## Point a client at it

Any OpenAI-compatible client works — set its base URL, and a key only if
`REQUIRE_API_KEY=true`:

```bash
OPENAI_BASE_URL=http://localhost:20128/v1              # from the host
OPENAI_BASE_URL=http://host.docker.internal:20128/v1   # from another compose stack
OPENAI_API_KEY=<gateway key, or any placeholder when REQUIRE_API_KEY=false>
```

If a client stack bundles its own `omniroute` service, that copy is redundant
once this one runs. Start that stack without it, or give it a different
published port so the two never contend for 20128.

## Data and upgrades

Everything persistent is on the `omniroute-data` volume: routing config,
encrypted provider credentials, and minted gateway keys. `down -v` destroys all
three and they have to be recreated.

The version is pinned via `OMNIROUTE_VERSION` in the `Dockerfile`, not tracked
as `latest`: clients cannot answer a single request without this service, so
bumps are deliberate. Currently pinned to **3.8.50**.

```bash
docker compose build --build-arg OMNIROUTE_VERSION=<new-version> \
  && docker compose up -d
```

## Upstream

OmniRoute itself is MIT-licensed, by
[diegosouzapw](https://github.com/diegosouzapw/OmniRoute). This repo only
packages it, and the packaging is MIT-licensed too — see [LICENSE](LICENSE).
