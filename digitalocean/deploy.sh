#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-paperclip}"
REGION="${REGION:-nyc3}"
SIZE="${SIZE:-s-2vcpu-4gb}"
IMAGE="${IMAGE:-ubuntu-24-04-x64}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! command -v doctl &>/dev/null; then
  echo "[!] doctl not found. Install from https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

if [ ! -f "${DIR}/.env" ]; then
  cp "${DIR}/.env.example" "${DIR}/.env"
fi

# Auto-generate secrets if not already set
if ! grep -q "^BETTER_AUTH_SECRET=.\+" "${DIR}/.env"; then
  sed -i.bak "s|^BETTER_AUTH_SECRET=.*|BETTER_AUTH_SECRET=$(openssl rand -hex 32)|" "${DIR}/.env"
  echo "[+] Generated BETTER_AUTH_SECRET."
fi
if ! grep -q "^PAPERCLIP_AGENT_JWT_SECRET=.\+" "${DIR}/.env"; then
  sed -i.bak "s|^PAPERCLIP_AGENT_JWT_SECRET=.*|PAPERCLIP_AGENT_JWT_SECRET=$(openssl rand -hex 32)|" "${DIR}/.env"
  echo "[+] Generated PAPERCLIP_AGENT_JWT_SECRET."
fi
rm -f "${DIR}/.env.bak"

source "${DIR}/.env"


# Domain prompt — always show, display current value if set
CURRENT_DOMAIN=$(grep "^CADDY_DOMAIN=.\+" "${DIR}/.env" | cut -d= -f2 || true)
echo ""
if [ -n "${CURRENT_DOMAIN}" ]; then
  read -r -p "[?] Domain for HTTPS [${CURRENT_DOMAIN}] (Enter to keep, or type new): " DOMAIN_INPUT
  DOMAIN_INPUT="${DOMAIN_INPUT:-${CURRENT_DOMAIN}}"
else
  read -r -p "[?] Domain for HTTPS (e.g. paperclip.yourdomain.com), or Enter for IP-only HTTP: " DOMAIN_INPUT
fi
if [ -n "$DOMAIN_INPUT" ]; then
  sed -i.bak "s|^CADDY_DOMAIN=.*|CADDY_DOMAIN=${DOMAIN_INPUT}|" "${DIR}/.env"
  rm -f "${DIR}/.env.bak"
  echo "[+] Domain set to ${DOMAIN_INPUT}."
fi

# LLM provider prompt — always show, skip if already configured
CURRENT_LLM=""
grep -q "^ANTHROPIC_API_KEY=.\+" "${DIR}/.env" && CURRENT_LLM="Anthropic" || true
grep -q "^OPENAI_API_KEY=.\+" "${DIR}/.env" && CURRENT_LLM="OpenAI" || true
grep -q "^GEMINI_API_KEY=.\+" "${DIR}/.env" && CURRENT_LLM="Gemini" || true
echo ""
if [ -n "$CURRENT_LLM" ]; then
  echo "[+] LLM provider already configured: ${CURRENT_LLM}. Edit .env to change."
else
  echo "[?] Select LLM provider (required to run agents):"
  echo "    1) Anthropic"
  echo "    2) OpenAI"
  echo "    3) Gemini"
  echo "    4) Skip (add later)"
  read -r -p "    Choice [1-4]: " LLM_CHOICE
  case "$LLM_CHOICE" in
    1) read -r -p "    Anthropic API key: " KEY_INPUT
       [ -n "$KEY_INPUT" ] && sed -i.bak "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${KEY_INPUT}|" "${DIR}/.env" ;;
    2) read -r -p "    OpenAI API key: " KEY_INPUT
       [ -n "$KEY_INPUT" ] && sed -i.bak "s|^OPENAI_API_KEY=.*|OPENAI_API_KEY=${KEY_INPUT}|" "${DIR}/.env" ;;
    3) read -r -p "    Gemini API key: " KEY_INPUT
       [ -n "$KEY_INPUT" ] && sed -i.bak "s|^GEMINI_API_KEY=.*|GEMINI_API_KEY=${KEY_INPUT}|" "${DIR}/.env" ;;
    *) echo "[+] Skipping LLM key. Add later via: nano /opt/paperclip/.env" ;;
  esac
  rm -f "${DIR}/.env.bak"
fi
# ---------------------------------------------------------------------------
# Create droplet
# ---------------------------------------------------------------------------
SSH_KEY_ID=$(doctl compute ssh-key list --format ID --no-header | head -n1)
if [ -z "$SSH_KEY_ID" ]; then
  echo "[!] No SSH keys found in your DO account. Upload one first: doctl compute ssh-key import"
  exit 1
fi

echo "[+] Creating droplet: $NAME ($SIZE in $REGION)..."
doctl compute droplet create "$NAME" \
  --region "$REGION" \
  --size "$SIZE" \
  --image "$IMAGE" \
  --ssh-keys "$SSH_KEY_ID" \
  --wait

IP=$(doctl compute droplet list "$NAME" --format PublicIPv4 --no-header | head -n1)
echo "[+] Droplet IP: $IP"

# Set public URL — use domain if CADDY_DOMAIN is set, otherwise fall back to IP
source "${DIR}/.env"
if [ -n "${CADDY_DOMAIN:-}" ]; then
  PUBLIC_URL="https://${CADDY_DOMAIN}"
  HOSTNAME="${CADDY_DOMAIN}"
else
  PUBLIC_URL="http://${IP}:3100"
  HOSTNAME="${IP}"
  sed -i.bak "s|^CADDY_DOMAIN=.*|CADDY_DOMAIN=|" "${DIR}/.env"
fi
sed -i.bak "s|^PAPERCLIP_PUBLIC_URL=.*|PAPERCLIP_PUBLIC_URL=${PUBLIC_URL}|" "${DIR}/.env"
sed -i.bak "s|^PAPERCLIP_ALLOWED_HOSTNAMES=.*|PAPERCLIP_ALLOWED_HOSTNAMES=${HOSTNAME}|" "${DIR}/.env"
rm -f "${DIR}/.env.bak"
# ---------------------------------------------------------------------------
# Wait for SSH
# ---------------------------------------------------------------------------
echo "[+] Waiting for SSH..."
until ssh -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 \
          root@"$IP" "echo ready" >/dev/null 2>&1; do
  sleep 5
done
echo "[+] SSH ready."

# ---------------------------------------------------------------------------
# Install Docker
# ---------------------------------------------------------------------------
echo "[+] Installing Docker..."
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@"$IP" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
while pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; do sleep 2; done
apt-get update -qq
apt-get upgrade -y -qq

apt-get install -y --no-install-recommends ca-certificates curl ufw

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{"dns": ["8.8.8.8", "1.1.1.1"]}
EOF
systemctl restart docker
mkdir -p /opt/paperclip

# Add 1GB swap as safety buffer
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
REMOTE

# ---------------------------------------------------------------------------
# Copy files and build
# ---------------------------------------------------------------------------
# Strip Windows line endings locally before copy
[ "$(uname)" = "Darwin" ] && sed -i '' $'s/\r$//' "${DIR}/entrypoint.sh" || sed -i 's/\r$//' "${DIR}/entrypoint.sh"
echo "[+] Copying files..."
for f in Dockerfile entrypoint.sh docker-compose.yml .env; do
  scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${DIR}/${f}" root@"$IP":/opt/paperclip/"${f}"
  echo "    copied ${f} ($(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$IP" "wc -c < /opt/paperclip/${f}") bytes)"
done

echo "[+] Building and starting Paperclip..."
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@"$IP" bash -s -- "${CADDY_DOMAIN:-}" <<'REMOTE'
set -euo pipefail
CADDY_DOMAIN="$1"
cd /opt/paperclip
sed -i 's/\r$//' entrypoint.sh && chmod +x entrypoint.sh
docker compose build
if [ -n "$CADDY_DOMAIN" ]; then
  COMPOSE_PROFILES=https docker compose up -d
else
  docker compose up -d
fi
REMOTE

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
echo "[+] Configuring firewall..."
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@"$IP" bash -s -- "${CADDY_DOMAIN:-}" <<'REMOTE'
CADDY_DOMAIN="$1"
ufw allow 22/tcp
if [ -n "$CADDY_DOMAIN" ]; then
  ufw allow 80/tcp
  ufw allow 443/tcp
else
  ufw allow 3100/tcp
fi
ufw --force enable
REMOTE

# ---------------------------------------------------------------------------
# Wait for Paperclip and extract invite URL
# ---------------------------------------------------------------------------
echo "[+] Waiting for Paperclip to start (this takes 2-3 minutes for the first build)..."
INVITE=""
for i in $(seq 1 24); do
  INVITE=$(ssh -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               root@"$IP" \
               "docker logs paperclip 2>&1 | grep -Eo 'https?://[^ ]*invite[^ ]*' | tail -n1" 2>/dev/null || true)
  if [ -n "$INVITE" ]; then
    break
  fi
  echo "    waiting... (${i}/24)"
  sleep 15
done

echo ""
echo "========================================="
echo "  Paperclip deployed"
echo "========================================="
echo "  IP:         $IP"
echo "  URL:        ${PUBLIC_URL}"
echo "  Admin SSH:  ssh root@$IP"
echo "========================================="
if [ -n "${INVITE:-}" ]; then
  echo "  Invite URL: $INVITE"
else
  echo "  Invite URL: not yet available — run:"
  echo "  ssh root@$IP \"docker logs paperclip 2>&1 | grep invite\""
fi
echo "========================================="
echo "  After sign-up, run:"
echo "  ssh root@$IP 'sed -i s/PAPERCLIP_AUTH_DISABLE_SIGN_UP=.*/PAPERCLIP_AUTH_DISABLE_SIGN_UP=true/ /opt/paperclip/.env && cd /opt/paperclip && docker compose up -d'"
echo "  To add LLM keys: ssh root@$IP, then: nano /opt/paperclip/.env && cd /opt/paperclip && docker compose up -d"
if [ -n "${CADDY_DOMAIN:-}" ]; then
echo ""
echo "  DNS: ensure ${CADDY_DOMAIN} points to ${IP}"
echo "  Caddy will auto-provision HTTPS on first request"
fi
echo "========================================="
