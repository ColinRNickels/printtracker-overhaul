#!/usr/bin/env bash
# ----------------------------------------------------------------
# start_tunnel.sh
#
# Launched by the cloudflared-quick systemd service.  It:
#   1. Starts a Cloudflare quick tunnel in the background.
#   2. Waits for the tunnel URL to appear in stdout/stderr.
#   3. Updates KIOSK_BASE_URL in the .env file.
#   4. PATCHes the go.ncsu.edu short link to point at the new URL.
#   5. Restarts the print-tracker service so it picks up the new URL.
#   6. Keeps cloudflared running in the foreground (for systemd).
# ----------------------------------------------------------------
set -Euo pipefail

# ----- Configuration (override via environment) ----- #
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
SERVICE_NAME="${SERVICE_NAME:-print-tracker}"
APP_PORT="${APP_PORT:-5000}"
ENV_FILE="${ENV_FILE:-}"
GO_NCSU_API_TOKEN="${GO_NCSU_API_TOKEN:-}"
GO_NCSU_LINK_SLUG="${GO_NCSU_LINK_SLUG:-makerspace-print-label}"
MAX_WAIT="${TUNNEL_WAIT_SECONDS:-60}"
NET_WAIT="${NETWORK_WAIT_SECONDS:-60}"

# Resolve ENV_FILE: if not supplied, look next to this script's parent dir
if [[ -z "${ENV_FILE}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  APP_DIR="$(dirname "${SCRIPT_DIR}")"
  ENV_FILE="${APP_DIR}/.env"
fi

log()  { printf '[tunnel] %s\n' "$*"; }
warn() { printf '[tunnel] WARNING: %s\n' "$*" >&2; }
die()  { printf '[tunnel] ERROR: %s\n' "$*" >&2; exit 1; }

# ----- Helper: upsert a key=value in a .env file ----- #
set_env_value() {
  local env_file="$1" key="$2" value="$3"
  python3 - "${env_file}" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

if env_path.exists():
    lines = env_path.read_text().splitlines()
else:
    lines = []

needle = f"{key}="
updated = []
found = False
for line in lines:
    if line.startswith(needle):
        updated.append(f"{key}={value}")
        found = True
    else:
        updated.append(line)

if not found:
    updated.append(f"{key}={value}")

env_path.write_text("\n".join(updated).rstrip() + "\n")
PY
}

# ----- Helper: read a key from .env ----- #
get_env_value() {
  local env_file="$1" key="$2"
  python3 - "${env_file}" "${key}" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]

if not env_path.exists():
    sys.exit(0)

for line in env_path.read_text().splitlines():
    if line.startswith(f"{key}="):
        print(line.split("=", 1)[1])
        break
PY
}

# ----- Load token from .env if not set in env ----- #
if [[ -z "${GO_NCSU_API_TOKEN}" && -f "${ENV_FILE}" ]]; then
  GO_NCSU_API_TOKEN="$(get_env_value "${ENV_FILE}" "GO_NCSU_API_TOKEN")"
fi
if [[ -z "${GO_NCSU_LINK_SLUG}" && -f "${ENV_FILE}" ]]; then
  GO_NCSU_LINK_SLUG="$(get_env_value "${ENV_FILE}" "GO_NCSU_LINK_SLUG")"
fi

# ----- Wait for network connectivity ----- #
net_elapsed=0
while [[ ${net_elapsed} -lt ${NET_WAIT} ]]; do
  if curl --silent --max-time 3 --head https://cloudflare.com >/dev/null 2>&1; then
    log "Network is reachable."
    break
  fi
  log "Waiting for network... (${net_elapsed}/${NET_WAIT}s)"
  sleep 3
  net_elapsed=$((net_elapsed + 3))
done
if [[ ${net_elapsed} -ge ${NET_WAIT} ]]; then
  warn "Network not reachable after ${NET_WAIT}s — starting cloudflared anyway."
fi

# ----- Start cloudflared in the background, capture output ----- #
TUNNEL_LOG="$(mktemp /tmp/cloudflared-tunnel-XXXX.log)"
trap 'rm -f "${TUNNEL_LOG}"' EXIT

log "Starting cloudflared quick tunnel on port ${APP_PORT}..."
cloudflared tunnel --url "http://localhost:${APP_PORT}" 2>&1 \
  | tee "${TUNNEL_LOG}" &
CFD_PID=$!

# ----- Wait for the tunnel URL to appear ----- #
TUNNEL_URL=""
elapsed=0
while [[ ${elapsed} -lt ${MAX_WAIT} ]]; do
  TUNNEL_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${TUNNEL_LOG}" | tail -1 || true)"
  if [[ -n "${TUNNEL_URL}" ]]; then
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if [[ -z "${TUNNEL_URL}" ]]; then
  warn "Could not detect tunnel URL after ${MAX_WAIT}s. Tunnel may still be starting."
  warn "cloudflared will keep running. Check: grep trycloudflare ${TUNNEL_LOG}"
  # Still wait on cloudflared so systemd sees the process
  wait "${CFD_PID}" || true
  exit 0
fi

log "Tunnel URL: ${TUNNEL_URL}"

# ----- Update KIOSK_BASE_URL in .env ----- #
if [[ -f "${ENV_FILE}" ]]; then
  log "Updating KIOSK_BASE_URL in ${ENV_FILE}..."
  set_env_value "${ENV_FILE}" "KIOSK_BASE_URL" "${TUNNEL_URL}"
else
  warn ".env not found at ${ENV_FILE}; skipping KIOSK_BASE_URL update."
fi

# ----- PATCH go.ncsu.edu short link ----- #
if [[ -n "${GO_NCSU_API_TOKEN}" && -n "${GO_NCSU_LINK_SLUG}" ]]; then
  GO_API_URL="https://go.ncsu.edu/api/v2/links/${GO_NCSU_LINK_SLUG}"
  log "Updating go.ncsu.edu link (${GO_NCSU_LINK_SLUG}) → ${TUNNEL_URL} ..."

  RESPONSE_FILE="$(mktemp /tmp/golink-resp-XXXX.json)"
  HTTP_CODE="$(curl --silent --location --output "${RESPONSE_FILE}" --write-out '%{http_code}' \
    --request PATCH \
    "${GO_API_URL}" \
    --header "Authorization: Bearer ${GO_NCSU_API_TOKEN}" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --data "{
      \"target_url\": \"${TUNNEL_URL}\",
      \"enabled\": true,
      \"exclude_from_status_check\": true
    }")" || true
  RESPONSE_BODY="$(cat "${RESPONSE_FILE}" 2>/dev/null)"
  rm -f "${RESPONSE_FILE}"

  if [[ "${HTTP_CODE}" =~ ^2[0-9][0-9]$ ]]; then
    log "go.ncsu.edu link updated successfully (HTTP ${HTTP_CODE})."
  else
    warn "go.ncsu.edu API returned HTTP ${HTTP_CODE}. Link may not have been updated."
    warn "Response: ${RESPONSE_BODY}"
  fi
else
  warn "GO_NCSU_API_TOKEN or GO_NCSU_LINK_SLUG not set; skipping go.ncsu.edu update."
fi

# ----- Restart print-tracker so it picks up the new KIOSK_BASE_URL ----- #
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  log "Restarting ${SERVICE_NAME} to pick up new KIOSK_BASE_URL..."
  systemctl restart "${SERVICE_NAME}" || warn "Failed to restart ${SERVICE_NAME}."
else
  warn "${SERVICE_NAME}.service not found; skipping restart."
fi

log "Tunnel is running. Waiting on cloudflared (PID ${CFD_PID})..."
wait "${CFD_PID}" || true
