# Paperclip on Railway

Deploy [Paperclip](https://github.com/paperclipai/paperclip), the open-source AI agent orchestration platform, on [Railway](https://railway.com/?referralCode=alphasec) with a single click. The template provisions Paperclip with a managed Railway Postgres database, a persistent volume, and automatic HTTPS.

See [this](https://alphasec.io/stop-hiring-start-orchestrating-running-an-ai-agent-company-with-paperclip-on-railway) companion blog post for a step-by-step walkthrough.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/paperclip-ai-agent-company?referralCode=alphasec)

## Prerequisites

- A [Railway](https://railway.com/?referralCode=alphasec) account
- An API key from at least one LLM provider (Anthropic, OpenAI, or Gemini)

## Configuration

| Variable | Description |
|---|---|
| `BETTER_AUTH_SECRET` | Auto-generated on deploy |
| `PAPERCLIP_AGENT_JWT_SECRET` | Auto-generated on deploy |
| `PAPERCLIP_PUBLIC_URL` | Auto-set from the Railway public domain |
| `DATABASE_URL` | Auto-wired to the Railway Postgres service |
| `PAPERCLIP_AUTH_DISABLE_SIGN_UP` | Optional. Leave unset for automatic lockdown, `false` to keep sign-up open, `true` to close it now |
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude agents |
| `OPENAI_API_KEY` | OpenAI API key for GPT agents |
| `GEMINI_API_KEY` | Gemini API key for Gemini agents via opencode |

## Post-Deploy

1. Find the bootstrap admin invite URL in the service logs: open the active deployment → **View logs** → search **Deploy logs** for `invite`. The invite expires after 72 hours.
2. Open the invite URL, create your admin account, then set up your company with its first agent and task.
3. Sign-up closes automatically once the admin account exists. The service restarts once to apply this; the logs show `entrypoint: admin claimed, restarting to disable sign-up`.

If you deploy this repo into your own service rather than via the template, set the healthcheck path to `/api/health` and the restart policy to **Always**. The entrypoint exits cleanly to apply the sign-up lockdown, so an **On Failure** policy would leave the service stopped.

## Agents

Paperclip's built-in adapters work out of the box with environment variables:

| Provider | Adapter | Required Variable |
|---|---|---|
| Anthropic | `claude_local` | `ANTHROPIC_API_KEY` |
| OpenAI | `opencode_local` | `OPENAI_API_KEY` |
| Gemini | `opencode_local` | `GEMINI_API_KEY` |

For Gemini, select `opencode_local` as the adapter in Paperclip's agent settings and choose your Gemini model. The `gemini_local` adapter requires interactive OAuth and won't work in a Railway container.

## Implementation Details

The image wraps the official `ghcr.io/paperclipai/paperclip:latest` image without replacing its startup chain: `tini` stays PID 1 to reap agent subprocesses, the upstream entrypoint still fixes volume ownership and drops to the `node` user, and the upstream production command runs unchanged. The added `entrypoint.sh` writes a minimal `config.json` on first boot, prints the bootstrap admin invite to the logs, and closes sign-up once the admin account exists. Secrets and `DATABASE_URL` stay in Railway Variables and are never written to the config file.

## Related

- [Deploy Paperclip on DigitalOcean](../digitalocean/README.md)
- [Stop Hiring, Start Orchestrating: Running an AI Agent Company with Paperclip on Railway](https://alphasec.io/stop-hiring-start-orchestrating-running-an-ai-agent-company-with-paperclip-on-railway)
- [Paperclip documentation](https://docs.paperclip.ing)
