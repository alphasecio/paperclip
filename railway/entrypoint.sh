#!/bin/sh
set -e

INSTANCE_DIR="/paperclip/instances/default"
CONFIG_FILE="${INSTANCE_DIR}/config.json"
ENV_FILE="${INSTANCE_DIR}/.env"
SECRETS_DIR="${INSTANCE_DIR}/secrets"
LOGS_DIR="${INSTANCE_DIR}/logs"
STORAGE_DIR="${INSTANCE_DIR}/data/storage"

: "${BETTER_AUTH_SECRET:?BETTER_AUTH_SECRET is required}"
: "${PAPERCLIP_PUBLIC_URL:?PAPERCLIP_PUBLIC_URL is required}"
: "${PAPERCLIP_ALLOWED_HOSTNAMES:?PAPERCLIP_ALLOWED_HOSTNAMES is required}"

chown node:node /paperclip
gosu node mkdir -p "${INSTANCE_DIR}" "${SECRETS_DIR}" "${LOGS_DIR}" "${STORAGE_DIR}"

if [ ! -f "${CONFIG_FILE}" ] || [ "${PAPERCLIP_FORCE_REINIT:-0}" = "1" ]; then
  PUBLIC_URL="${PAPERCLIP_PUBLIC_URL%/}"
  HOSTNAMES_JSON=$(echo "${PAPERCLIP_ALLOWED_HOSTNAMES}" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | awk '{ printf "\"%s\",", $0 }' \
    | sed 's/,$//')

  if [ -n "${DATABASE_URL:-}" ]; then
    DB_BLOCK="\"database\": { \"provider\": \"postgres\", \"postgres\": { \"url\": \"${DATABASE_URL}\" } }"
  else
    DB_BLOCK="\"database\": { \"provider\": \"embedded-postgres\" }"
  fi

  gosu node tee "${CONFIG_FILE}" > /dev/null <<EOF
{
  "\$meta": { "version": 1, "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "source": "onboard" },
  ${DB_BLOCK},
  "server": {
    "host": "0.0.0.0",
    "port": 3100,
    "deploymentMode": "authenticated",
    "exposure": "public",
    "allowedHostnames": [${HOSTNAMES_JSON}]
  },
  "auth": { "baseUrlMode": "explicit", "publicBaseUrl": "${PUBLIC_URL}" },
  "storage": { "provider": "local_disk", "localDisk": { "dir": "${STORAGE_DIR}" } },
  "secrets": { "provider": "local_encrypted", "localEncrypted": { "keyFilePath": "${SECRETS_DIR}/master.key" } },
  "logging": { "mode": "file", "dir": "${LOGS_DIR}" }
}
EOF
fi

if [ ! -f "${ENV_FILE}" ]; then
  gosu node tee "${ENV_FILE}" > /dev/null <<EOF
PAPERCLIP_AGENT_JWT_SECRET=${PAPERCLIP_AGENT_JWT_SECRET:-${BETTER_AUTH_SECRET}}
EOF
fi

cd /app
exec gosu node pnpm paperclipai run
