#!/bin/sh
set -eu

: "${BETTER_AUTH_SECRET:?BETTER_AUTH_SECRET is required}"
: "${PAPERCLIP_PUBLIC_URL:?PAPERCLIP_PUBLIC_URL is required}"
case "$PAPERCLIP_PUBLIC_URL" in
  https://*) ;;
  *) echo "entrypoint: PAPERCLIP_PUBLIC_URL must start with https://" >&2; exit 1 ;;
esac

HOME_DIR="${PAPERCLIP_HOME:-/paperclip}"
CONFIG="${PAPERCLIP_CONFIG:-$HOME_DIR/instances/default/config.json}"
CLAIMED="$HOME_DIR/.admin-claimed"
PUBLIC_URL="${PAPERCLIP_PUBLIC_URL%/}"
HEALTH="http://127.0.0.1:${PORT:-3100}/api/health"

if [ ! -f "$CONFIG" ]; then
  DB_MODE="embedded-postgres"
  [ -n "${DATABASE_URL:-}" ] && DB_MODE="postgres"
  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<EOF
{
  "\$meta": { "version": 1, "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "source": "onboard" },
  "database": { "mode": "$DB_MODE" },
  "logging": { "mode": "file" },
  "server": { "deploymentMode": "authenticated", "exposure": "public", "host": "0.0.0.0", "port": 3100 },
  "auth": { "baseUrlMode": "explicit", "publicBaseUrl": "$PUBLIC_URL" },
  "telemetry": { "enabled": false }
}
EOF
fi

AUTO_LOCK=0
if [ -z "${PAPERCLIP_AUTH_DISABLE_SIGN_UP:-}" ]; then
  if [ -f "$CLAIMED" ]; then
    export PAPERCLIP_AUTH_DISABLE_SIGN_UP=true
    echo "entrypoint: admin exists, sign-up disabled"
  else
    AUTO_LOCK=1
  fi
fi

status() {
  node -e "fetch('$HEALTH').then(r=>r.json()).then(j=>console.log(j.bootstrapStatus||''),()=>console.log(''))"
}

SERVER_PID=$$
(
  cd /app
  tries=0
  until [ -n "$(status)" ]; do
    tries=$((tries + 1))
    [ "$tries" -ge 120 ] && exit 0
    sleep 5
  done

  if [ "$(status)" = "bootstrap_pending" ]; then
    gosu node node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo || true
  fi

  [ "$AUTO_LOCK" -eq 1 ] || exit 0
  until [ "$(status)" = "ready" ]; do sleep 30; done
  gosu node touch "$CLAIMED"
  echo "entrypoint: admin claimed, restarting to disable sign-up"
  kill -KILL "$SERVER_PID"
) &

exec upstream-entrypoint.sh "$@"
