# Paperclip on DigitalOcean

Deploy [Paperclip](https://github.com/paperclipai/paperclip) — the open-source AI agent orchestration platform — on a [DigitalOcean](https://m.do.co/c/5552e11c260f) droplet with a single script. Includes automatic HTTPS via Caddy, embedded PostgreSQL, and persistent storage. 

See [this](https://alphasec.io?stop-hiring-start-orchestrating-running-an-ai-agent-company-with-paperclip-on-digitalocean) companion blog post for a step-by-step walkthrough.

## Prerequisites

- [doctl](https://docs.digitalocean.com/reference/doctl/how-to/install/) installed and authenticated (`doctl auth init`)
- An SSH key uploaded to your DigitalOcean account
- A domain or subdomain pointing at your droplet IP (optional, for HTTPS)

## Deploy

```bash
git clone https://github.com/alphasecio/paperclip.git
cd paperclip/digitalocean
chmod +x deploy.sh
./deploy.sh
```

The script will:

1. Generate authentication secrets automatically
2. Prompt for your domain (optional — enables HTTPS via Caddy)
3. Prompt for an LLM provider API key (Anthropic, OpenAI, or Gemini)
4. Create a Droplet, install Docker, build and start Paperclip
5. Print the admin invite URL when ready

## Post-Deploy

Open the invite URL printed at the end of the script to create your admin account.

Optionally, once signed up, lock down further registrations:

```bash
ssh root@<your-droplet-ip> 'echo PAPERCLIP_AUTH_DISABLE_SIGN_UP=true >> /opt/paperclip/.env && cd /opt/paperclip && docker compose up -d'
```

## Configuration

| Variable | Description |
|---|---|
| `BETTER_AUTH_SECRET` | Auth secret — auto-generated |
| `PAPERCLIP_AGENT_JWT_SECRET` | Agent JWT secret — auto-generated |
| `CADDY_DOMAIN` | Your domain for HTTPS (e.g. `paperclip.yourdomain.com`) |
| `PAPERCLIP_PUBLIC_URL` | Auto-set from domain or IP |
| `PAPERCLIP_ALLOWED_HOSTNAMES` | Auto-set from domain or IP |
| `DATABASE_URL` | Optional — leave unset to use embedded PostgreSQL |
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude agents |
| `OPENAI_API_KEY` | OpenAI API key for GPT / Codex agents |
| `GEMINI_API_KEY` | Gemini API key for Gemini agents via opencode |
| `PAPERCLIP_AUTH_DISABLE_SIGN_UP` | Set to `true` after creating your admin account |

Edit `/opt/paperclip/.env` on the droplet and run `docker compose up -d` to apply changes.

## Customisation

**Droplet size** — default is `s-2vcpu-4gb` ($24/month). Override with:

```bash
SIZE=s-2vcpu-2gb ./deploy.sh
```

**Region** — default is `nyc3`. Override with:

```bash
REGION=sgp1 ./deploy.sh
```

**External PostgreSQL** — set `DATABASE_URL` in `.env` before deploying. The entrypoint automatically switches from embedded to external Postgres when this variable is present.

## Agents

Paperclip's built-in adapters work out of the box:

| Provider | Adapter | Required Variable |
|---|---|---|
| Anthropic | `claude_local` | `ANTHROPIC_API_KEY` |
| OpenAI | `opencode_local` | `OPENAI_API_KEY` |
| Gemini | `opencode_local` | `GEMINI_API_KEY` |

For Gemini, select `opencode_local` as the adapter in Paperclip's agent settings and choose your Gemini model (e.g. `gemini-2.5-flash`).

## Updating

```bash
ssh root@<your-droplet-ip>
cd /opt/paperclip
docker compose pull
docker compose up -d --build
```

## Related

- [Deploy Paperclip on Railway](../railway/README.md)
- [Stop Hiring, Start Orchestrating: Running an AI Agent Company with Paperclip on DigitalOcean](https://alphasec.io/stop-hiring-start-orchestrating-running-an-ai-agent-company-with-paperclip-on-digitalocean)
- [Paperclip documentation](https://docs.paperclip.ing)
