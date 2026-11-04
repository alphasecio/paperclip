# Paperclip on DigitalOcean

Deploy [Paperclip](https://github.com/paperclipai/paperclip), the open-source AI agent orchestration platform, on a [DigitalOcean](https://m.do.co/c/5552e11c260f) droplet with a single script. Includes automatic HTTPS via Caddy, embedded PostgreSQL, persistent storage, and automatic sign-up lockdown after the first admin account.

See [this](https://alphasec.io/stop-hiring-start-orchestrating-running-an-ai-agent-company-with-paperclip-on-digitalocean) companion blog post for a step-by-step walkthrough.

## Prerequisites

- [doctl](https://docs.digitalocean.com/reference/doctl/how-to/install/) installed and authenticated (`doctl auth init`)
- An SSH key uploaded to your DigitalOcean account
- A domain or subdomain you can point at the droplet IP (recommended, for HTTPS)

## Deploy

```bash
git clone https://github.com/alphasecio/paperclip.git
cd paperclip/digitalocean
chmod +x deploy.sh
./deploy.sh
```

The script will:

1. Generate authentication secrets
2. Prompt for your domain (enables HTTPS via Caddy; leave empty for IP-only HTTP)
3. Prompt for an LLM provider API key (Anthropic, OpenAI, or Gemini)
4. Create a droplet, install Docker, build and start Paperclip
5. Print the admin invite URL when ready

## Post-Deploy

1. If you used a domain, point its DNS A record at the droplet IP. Caddy provisions the certificate on the first request.
2. Open the invite URL printed at the end of the script and create your admin account. If it wasn't printed yet:
   ```bash
   ssh root@<droplet-ip> "docker logs paperclip 2>&1 | grep invite"
   ```
   The invite expires after 72 hours.
3. Sign-up closes automatically once the admin account exists. The container restarts once to apply this; the logs show `entrypoint: admin claimed, restarting to disable sign-up`.

IP-only mode serves plain HTTP on port 3100, so passwords and session cookies cross the network unencrypted. Use it for testing only.

## Configuration

| Variable | Description |
|---|---|
| `BETTER_AUTH_SECRET` | Auth secret, auto-generated |
| `PAPERCLIP_AGENT_JWT_SECRET` | Agent JWT secret, auto-generated |
| `CADDY_DOMAIN` | Your domain for HTTPS (e.g. `paperclip.yourdomain.com`) |
| `PAPERCLIP_PUBLIC_URL` | Auto-set from the domain or droplet IP |
| `PAPERCLIP_BIND` | Auto-set: `127.0.0.1` behind Caddy, `0.0.0.0` in IP-only mode |
| `COMPOSE_PROFILES` | Auto-set to `https` when a domain is used, so Caddy starts |
| `DATABASE_URL` | Optional. Leave unset to use embedded PostgreSQL |
| `PAPERCLIP_AUTH_DISABLE_SIGN_UP` | Optional. Leave unset for automatic lockdown, `false` to keep sign-up open, `true` to close it now |
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude agents |
| `OPENAI_API_KEY` | OpenAI API key for GPT agents |
| `GEMINI_API_KEY` | Gemini API key for Gemini agents via opencode |

To change settings, edit `/opt/paperclip/.env` on the droplet, then run `cd /opt/paperclip && docker compose up -d`.

## Customisation

**Droplet size**: default is `s-1vcpu-2gb` ($12/month) with 2GB swap. Paperclip idles at about 1GB; for several agents running at once, use a larger droplet:

```bash
SIZE=s-2vcpu-4gb ./deploy.sh
```

**Region**: default is `nyc3`:

```bash
REGION=sgp1 ./deploy.sh
```

**SSH key**: the first key in your account is used by default. To pick another, find its ID with `doctl compute ssh-key list` and run:

```bash
SSH_KEY_ID=<id> ./deploy.sh
```

**External PostgreSQL**: set `DATABASE_URL` in `.env` before deploying. The entrypoint switches from embedded to external Postgres when it's present.

## Agents

Paperclip's built-in adapters work out of the box:

| Provider | Adapter | Required Variable |
|---|---|---|
| Anthropic | `claude_local` | `ANTHROPIC_API_KEY` |
| OpenAI | `opencode_local` | `OPENAI_API_KEY` |
| Gemini | `opencode_local` | `GEMINI_API_KEY` |

For Gemini, select `opencode_local` as the adapter in Paperclip's agent settings and choose your Gemini model. The `gemini_local` adapter requires interactive OAuth and won't work on a headless server.

## Updating

The image tracks Paperclip's stable `latest` release. To update:

```bash
ssh root@<droplet-ip>
cd /opt/paperclip
docker compose build --pull
docker compose up -d
```

## Implementation Details

The image wraps the official `ghcr.io/paperclipai/paperclip:latest` image without replacing its startup chain: `tini` stays PID 1 to reap agent subprocesses, the upstream entrypoint still fixes volume ownership and drops to the `node` user, and the upstream production command runs unchanged. The added `entrypoint.sh` writes a minimal `config.json` on first boot, prints the bootstrap admin invite to the logs, and closes sign-up once the admin account exists. Secrets stay in `.env` and are never written to the config file.

## Related

- [Deploy Paperclip on Railway](../railway/README.md)
- [Stop Hiring, Start Orchestrating: Running an AI Agent Company with Paperclip on DigitalOcean](https://alphasec.io/stop-hiring-start-orchestrating-running-an-ai-agent-company-with-paperclip-on-digitalocean)
- [Paperclip documentation](https://docs.paperclip.ing)
