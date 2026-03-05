#!/usr/bin/env bash
# ----------------------------------------------------------------
# get_tunnel_url.sh — Print the current Cloudflare quick-tunnel URL.
#
# Checks journalctl for the cloudflared-quick service, then falls
# back to reading KIOSK_BASE_URL from .env.
# ----------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ENV_FILE:-${APP_DIR}/.env}"

# --- Try journalctl first (most current) ---
TUNNEL_URL=""
if command -v journalctl >/dev/null 2>&1; then
  TUNNEL_URL="$(journalctl -u cloudflared-quick --no-pager -n 80 2>/dev/null \
    | grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
fi

# --- Fallback: read KIOSK_BASE_URL from .env ---
if [[ -z "${TUNNEL_URL}" && -f "${ENV_FILE}" ]]; then
  TUNNEL_URL="$(python3 - "${ENV_FILE}" <<'PY'
from pathlib import Path
import sys
env = Path(sys.argv[1])
if env.exists():
    for line in env.read_text().splitlines():
        if line.startswith("KIOSK_BASE_URL="):
            val = line.split("=", 1)[1].strip()
            if val and val != "http://localhost:5000":
                print(val)
            break
PY
  )" || true
fi

if [[ -n "${TUNNEL_URL}" ]]; then
  echo "${TUNNEL_URL}"
else
  echo "No tunnel URL found." >&2
  exit 1
fi
