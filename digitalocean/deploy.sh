#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-paperclip}"
REGION="${REGION:-nyc3}"
SIZE="${SIZE:-s-1vcpu-2gb}"
IMAGE="${IMAGE:-ubuntu-24-04-x64}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${DIR}/.env"
KNOWN_HOSTS="${DIR}/.known_hosts"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${KNOWN_HOSTS}" -o ConnectTimeout=10)

get_env() { grep "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true; }

set_env() {
  K="$1" V="$2" awk '
    index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }
  ' "$ENV_FILE" > "${ENV_FILE}.tmp"
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! command -v doctl &>/dev/null; then
  echo "[!] doctl not found. Install from https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  cp "${DIR}/.env.example" "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

for key in BETTER_AUTH_SECRET PAPERCLIP_AGENT_JWT_SECRET; do
  if [ -z "$(get_env "$key")" ]; then
    set_env "$key" "$(openssl rand -hex 32)"
    echo "[+] Generated ${key}."
  fi
done

# Domain
CURRENT_DOMAIN="$(get_env CADDY_DOMAIN)"
echo ""
if [ -n "$CURRENT_DOMAIN" ]; then
  read -r -p "[?] Domain for HTTPS [${CURRENT_DOMAIN}] (Enter to keep, or type new): " DOMAIN_INPUT
  DOMAIN_INPUT="${DOMAIN_INPUT:-$CURRENT_DOMAIN}"
else
  read -r -p "[?] Domain for HTTPS (e.g. paperclip.yourdomain.com), or Enter for IP-only HTTP: " DOMAIN_INPUT
fi
set_env CADDY_DOMAIN "$DOMAIN_INPUT"

# LLM provider
CURRENT_LLM=""
[ -n "$(get_env ANTHROPIC_API_KEY)" ] && CURRENT_LLM="Anthropic"
[ -n "$(get_env OPENAI_API_KEY)" ] && CURRENT_LLM="OpenAI"
[ -n "$(get_env GEMINI_API_KEY)" ] && CURRENT_LLM="Gemini"
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
    1) KEY_NAME=ANTHROPIC_API_KEY ;;
    2) KEY_NAME=OPENAI_API_KEY ;;
    3) KEY_NAME=GEMINI_API_KEY ;;
    *) KEY_NAME="" ;;
  esac
  if [ -n "$KEY_NAME" ]; then
    read -r -s -p "    ${KEY_NAME}: " KEY_INPUT
    echo ""
    if [ -n "$KEY_INPUT" ]; then
      set_env "$KEY_NAME" "$KEY_INPUT"
    fi
  else
    echo "[+] Skipping LLM key. Add it later in /opt/paperclip/.env on the droplet."
  fi
fi

# ---------------------------------------------------------------------------
# Create droplet
# ---------------------------------------------------------------------------
SSH_KEY_ID="${SSH_KEY_ID:-$(doctl compute ssh-key list --format ID --no-header | head -n1)}"
if [ -z "$SSH_KEY_ID" ]; then
  echo "[!] No SSH keys found in your DO account. Upload one first: doctl compute ssh-key import"
  exit 1
fi

echo "[+] Creating droplet: $NAME ($SIZE in $REGION, SSH key $SSH_KEY_ID)..."
doctl compute droplet create "$NAME" \
  --region "$REGION" \
  --size "$SIZE" \
  --image "$IMAGE" \
  --ssh-keys "$SSH_KEY_ID" \
  --wait

IP=$(doctl compute droplet list "$NAME" --format PublicIPv4 --no-header | head -n1)
echo "[+] Droplet IP: $IP"
rm -f "$KNOWN_HOSTS"

DOMAIN="$(get_env CADDY_DOMAIN)"
if [ -n "$DOMAIN" ]; then
  PUBLIC_URL="https://${DOMAIN}"
  set_env PAPERCLIP_BIND 127.0.0.1
  set_env COMPOSE_PROFILES https
else
  PUBLIC_URL="http://${IP}:3100"
  set_env PAPERCLIP_BIND 0.0.0.0
  set_env COMPOSE_PROFILES ""
fi
set_env PAPERCLIP_PUBLIC_URL "$PUBLIC_URL"

# ---------------------------------------------------------------------------
# Wait for SSH
# ---------------------------------------------------------------------------
echo "[+] Waiting for SSH..."
until ssh "${SSH_OPTS[@]}" root@"$IP" "echo ready" >/dev/null 2>&1; do
  sleep 5
done
echo "[+] SSH ready."

# ---------------------------------------------------------------------------
# Install Docker
# ---------------------------------------------------------------------------
echo "[+] Installing Docker..."
ssh "${SSH_OPTS[@]}" root@"$IP" <<'REMOTE'
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
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl start unattended-upgrades 2>/dev/null || true

mkdir -p /opt/paperclip

if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
REMOTE

# ---------------------------------------------------------------------------
# Copy files and start
# ---------------------------------------------------------------------------
echo "[+] Copying files..."
scp "${SSH_OPTS[@]}" -q \
  "${DIR}/Dockerfile" "${DIR}/entrypoint.sh" "${DIR}/docker-compose.yml" "${DIR}/.env" \
  root@"$IP":/opt/paperclip/

echo "[+] Building and starting Paperclip..."
ssh "${SSH_OPTS[@]}" root@"$IP" <<'REMOTE'
set -euo pipefail
cd /opt/paperclip
chmod 600 .env
sed -i 's/\r$//' entrypoint.sh
docker compose up -d --build
REMOTE

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
echo "[+] Configuring firewall..."
ssh "${SSH_OPTS[@]}" root@"$IP" bash -s -- "$DOMAIN" <<'REMOTE'
set -euo pipefail
ufw allow 22/tcp
if [ -n "$1" ]; then
  ufw allow 80/tcp
  ufw allow 443/tcp
else
  ufw allow 3100/tcp
fi
ufw --force enable
REMOTE

# ---------------------------------------------------------------------------
# Wait for the bootstrap invite
# ---------------------------------------------------------------------------
echo "[+] Waiting for Paperclip to start..."
INVITE=""
for i in $(seq 1 24); do
  INVITE=$(ssh "${SSH_OPTS[@]}" root@"$IP" \
    "docker logs paperclip 2>&1 | grep -Eo 'https?://[^ ]*/invite/[^ ]*' | tail -n1" 2>/dev/null || true)
  [ -n "$INVITE" ] && break
  echo "    waiting... (${i}/24)"
  sleep 15
done

echo ""
echo "========================================="
echo "  Paperclip deployed"
echo "========================================="
echo "  IP:         $IP"
echo "  URL:        $PUBLIC_URL"
echo "  Admin SSH:  ssh root@$IP"
echo "========================================="
if [ -n "$INVITE" ]; then
  echo "  Invite URL: $INVITE"
else
  echo "  Invite URL: not yet available. Run:"
  echo "  ssh root@$IP \"docker logs paperclip 2>&1 | grep invite\""
fi
echo "  Sign-up closes automatically once the admin account is created."
echo "========================================="
echo "  To change settings: ssh root@$IP, edit /opt/paperclip/.env,"
echo "  then: cd /opt/paperclip && docker compose up -d"
if [ -n "$DOMAIN" ]; then
  echo ""
  echo "  DNS: ensure ${DOMAIN} points to ${IP}"
  echo "  Caddy provisions HTTPS on the first request"
else
  echo ""
  echo "  WARNING: IP-only mode serves plain HTTP. Use a domain for anything beyond testing."
fi
echo "========================================="
