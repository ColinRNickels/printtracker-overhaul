# Print Tracker

Print Tracker is a Flask app for managing 3D-print jobs across NC State
University Libraries makerspaces (Makerspace and Maker Studio).

**Patron workflow:**
A patron starts a 3D print, scans a QR code poster with their phone, fills
in the registration form, and a label prints at the space's label station.
They place the label next to their print and leave. When the print is
complete they receive an email and return to the Library Ask Us desk to
collect it.

**Staff workflow:**
Staff clear printers, bag each completed print, peel the label and stick it
on the bag. They scan the QR code on the label with their phone, log in
once, and mark the print Finished or Failed (failure notes are required).
The system emails the patron automatically and syncs completion data to
Google Sheets. Staff sort the bagged prints by patron last name at the
Ask Us desk.

**Key design choices:**

- Phone-first — patrons and staff use their own phones on campus Wi-Fi.
- SQLite for fast local operations, Google Sheets as the durable external
  record staff can browse directly.
- Gmail API for email, Google Sheets API for sync, both via OAuth refresh
  token.
- Flat data model for easy CSV/Sheets portability.
- Responsive UI that works in portrait on phones and landscape on laptops.

---

## Architecture

### MVP (current — Pi-only with Cloudflare Tunnel)

```
Student phone (campus Wi-Fi)
        │
        │  HTTPS
        ▼
┌──────────────────────────────┐
│  Cloudflare Tunnel (free)    │
│  makerspace-print.domain.com │
└──────────┬───────────────────┘
           │  localhost:5000
           ▼
┌──────────────────────────┐
│  Raspberry Pi            │
│  Flask + gunicorn        │
│  SQLite (WAL mode)       │
│  CUPS → Brother QL-800   │
│  Gmail API + Sheets sync │
└──────────────────────────┘
```

Each makerspace location runs its own Pi. A free Cloudflare Tunnel gives
each Pi a stable public HTTPS URL that students can reach from campus Wi-Fi
— no IT firewall changes, no DNS requests, no server provisioning.

### Production (future — server + Pi print relays)

When ready for IT involvement, the Flask app moves to a university server.
Each Pi becomes a lightweight print agent that polls the server for pending
labels. See [Architecture Roadmap](#architecture-roadmap) at the end of
this document.

---

## 1) What's Implemented

### Registration form (`/kiosk/register`)

- Collects: first name, last name, NCSU email, file name, project type
- Project type options: Personal, Academic, Research
  - Academic requires Course # and Instructor
  - Research requires Department and PI
- Responsive layout: single-column on phones, two-column on laptops
- Submit button: **Print Label**
- Success page auto-returns to start in 10 seconds

### Labels

- Brother DK-1202, landscape orientation by default
- Human-readable layout: "PRINT IN PROGRESS", name as `Last, First`,
  file name, project type, optional course/research details
- QR code at bottom-right links to staff completion page
- Optional logo from `LABEL_BRAND_LOGO_PATH`
- Saved label images with configurable retention

### Staff dashboard (`/staff/`)

- Password protected via `STAFF_PASSWORD`
- Scan QR or enter Print ID to open a job
- Mark Finished or Failed (failure notes required)
- Reprint buttons for in-progress and recent completed jobs
- Runtime settings: email toggle, label save, retention days, QR mode
- Login auto-returns to kiosk after 15s (disabled for QR-driven paths)

### Notifications + cloud

- Email via Gmail API (recommended), SMTP, or auto-fallback
- Google Sheets sync on register and on completion
- OAuth bootstrap script for headless or desktop setup

### Reports (`/reports/monthly`)

- Month picker, CSV export
- Charts: prints per month trend, project type pie, research departments,
  status breakdown

---

## 2) Quick Local Start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python run.py
```

Open:

- Kiosk: `http://localhost:5000/kiosk/register`
- Staff: `http://localhost:5000/staff/`
- Reports: `http://localhost:5000/reports/monthly`

If port 5000 is busy:

```bash
PORT=5050 python run.py
```

---

## 3) Raspberry Pi Deploy (Fresh Image)

### 3.1 One-time setup

Use Raspberry Pi OS Desktop (Bookworm or later). Plug the Pi into wired
Ethernet.

```bash
sudo apt update && sudo apt install -y git
sudo mkdir -p /opt/print-tracker
sudo chown -R "$USER:$USER" /opt/print-tracker
cd /opt/print-tracker
git clone <YOUR_REPO_URL> .
chmod +x scripts/deploy_rpi.sh
./scripts/deploy_rpi.sh
```

### 3.2 What the deploy script does

`scripts/deploy_rpi.sh` automates:

- apt packages (`cups`, `printer-driver-ptouch`, `network-manager`, etc.)
- Python virtualenv + dependencies
- `.env` creation/update
- DB init
- systemd service (`print-tracker`)
- Optional Wi-Fi AP for staff scanning (default ON but not required with
  Cloudflare Tunnel)
- Optional Chromium kiosk autostart (default ON but not required for
  phone-first workflow)
- Optional Google OAuth setup

### 3.3 Brother QL-800 setup (CUPS)

Printer queue needs manual CUPS configuration:

1. Plug in QL-800 via USB.
2. Open `http://localhost:631`.
3. Administration → Add Printer.
4. Select the Brother device and driver.
5. Set the queue name to match `.env` (default `QL800`).

Verify:

```bash
lpstat -e
lpstat -p -d
lp -d QL800 /usr/share/cups/data/testprint
```

### 3.4 Deploy script examples

```bash
# Accept all defaults
./scripts/deploy_rpi.sh --non-interactive

# Development/testing without a printer
./scripts/deploy_rpi.sh --print-mode mock

# Skip AP and kiosk browser (phone-first setup)
./scripts/deploy_rpi.sh --no-ap --no-kiosk-autostart

# Full Google OAuth setup
./scripts/deploy_rpi.sh \
  --setup-google-oauth \
  --google-client-secrets ~/Downloads/client_secret.json \
  --google-gmail-sender makerspace@ncsu.edu \
  --google-spreadsheet-id <SHEET_ID>
```

---

## 4) Cloudflare Tunnel Setup

Cloudflare Tunnel gives the Pi a public HTTPS URL so students on campus
Wi-Fi can reach the registration form on their phones. Free tier, no
domain purchase required.

### 4.1 Quick test (no account needed)

Run one command to get a temporary public URL:

```bash
cloudflared tunnel --url http://localhost:5000
```

It prints something like `https://random-words-here.trycloudflare.com`.
That URL is live immediately with automatic HTTPS. The URL changes on
every restart — fine for a demo, not for production.

### 4.2 Permanent tunnel (free Cloudflare account)

#### Create account

1. Go to https://dash.cloudflare.com/sign-up
2. Enter email + password, verify email
3. No domain, payment, or website required

#### Install cloudflared on the Pi

```bash
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/cloudflare-archive-keyring.gpg] \
  https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt update && sudo apt install -y cloudflared
```

#### Authenticate

```bash
cloudflared tunnel login
```

This prints a URL. Open it **on your laptop** (not the Pi), log in to
Cloudflare, and authorize. The Pi receives a certificate at
`~/.cloudflared/cert.pem`. This is a one-time step.

#### Create the tunnel

```bash
cloudflared tunnel create print-tracker
```

Note the tunnel ID (e.g., `abcd-1234-efgh-5678`). A credentials file is
created at `~/.cloudflared/<TUNNEL_ID>.json`.

#### Configure

Create `~/.cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /home/pi/.cloudflared/<TUNNEL_ID>.json

ingress:
  - service: http://localhost:5000
```

Replace the tunnel ID and path with your actual values.

#### Run as a system service

```bash
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

The tunnel starts on boot and reconnects automatically after network
interruptions.

#### Your stable URL

Without a custom domain, the Pi is reachable at:

```
https://<TUNNEL_ID>.cfargotunnel.com
```

This URL is permanent and HTTPS is automatic.

#### Update the app config

Set `KIOSK_BASE_URL` in `.env` to the tunnel URL:

```
KIOSK_BASE_URL=https://<TUNNEL_ID>.cfargotunnel.com
```

Restart the app:

```bash
sudo systemctl restart print-tracker
```

QR codes on labels now encode the public tunnel URL — scannable by staff
from any network.

### 4.3 Multiple locations

Each makerspace gets its own Pi with its own tunnel. Create a separate
tunnel for each:

```bash
# On Makerspace Pi
cloudflared tunnel create makerspace-print

# On Maker Studio Pi
cloudflared tunnel create maker-studio-print
```

Each gets its own stable URL. Post a QR code poster at each location
linking to its registration form.

### 4.4 Optional: custom domain

If you later get a domain (e.g., `lib-print.ncsu.edu`), add a DNS CNAME
in Cloudflare pointing to the tunnel:

```bash
cloudflared tunnel route dns print-tracker makerspace-print.yourdomain.com
```

No Pi reconfiguration needed — just update `KIOSK_BASE_URL`.

---

## 5) Google OAuth (Gmail + Sheets)

Google OAuth is used for both sending email (Gmail API) and syncing data
(Google Sheets API). The OAuth flow generates a refresh token that is
stored in `.env` and used for all API calls.

### 5.1 Create Google Cloud credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create or select a project
3. Enable **Gmail API** and **Google Sheets API**
4. Configure OAuth consent screen (Internal if using a Workspace account,
   or External with your account as a test user)
5. Create an OAuth Client ID → **Desktop app**
6. Download the client secrets JSON file

### 5.2 Generate the refresh token

You can run this on **any machine with a browser** — it does not have to
be the Pi or the server. The script prints the values you need to paste
into `.env`.

```bash
# On your laptop (recommended):
cd /path/to/print-tracker
source .venv/bin/activate
python scripts/google_oauth_bootstrap.py \
  --client-secrets ~/Downloads/client_secret.json \
  --gmail-sender makerspace@ncsu.edu
```

The script opens a browser for consent. After authorization, it prints
env values. Copy them into the Pi's `.env` (or the server's `.env` for
the production setup).

#### Headless / SSH option

If running on a headless machine via SSH, the script automatically falls
back to console mode: it prints a URL, you open it on any browser (phone
or laptop), complete consent, and paste the authorization code back into
the terminal.

### 5.3 Configure Sheets sync

1. Create a Google Sheet (or use an existing one)
2. Share it with the Google account that completed the OAuth flow
3. Set these values in `.env`:

```
GOOGLE_SHEETS_SYNC_ENABLED=true
GOOGLE_SHEETS_SPREADSHEET_ID=<your-spreadsheet-id>
GOOGLE_SHEETS_WORKSHEET=PrintJobs
```

4. Restart:

```bash
sudo systemctl restart print-tracker
```

The app creates the worksheet and headers automatically on first sync.

---

## 6) Key URLs

| URL | Purpose |
|-----|---------|
| `/kiosk/register` | Patron registration form |
| `/staff/` | Staff dashboard (password protected) |
| `/staff/s/<CODE>` | QR scan shortcut → staff completion page |
| `/staff/complete/<CODE>` | Staff completion form for a specific job |
| `/reports/monthly` | Monthly report with charts |
| `/reports/monthly.csv` | CSV export for the selected month |

---

## 7) Configuration Reference (`.env`)

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRET_KEY` | `change-me` | Flask session secret — change in production |
| `DATABASE_URL` | `sqlite:///instance/print_tracker.db` | SQLite database path |
| `STAFF_PASSWORD` | `staffpw` | Staff dashboard password — change in production |
| `DEFAULT_PRINTER_NAME` | `Makerspace` | Display name for the printer location |
| `KIOSK_BASE_URL` | `http://localhost:5000` | Public base URL for QR codes on labels |

### Label printing

| Variable | Default | Description |
|----------|---------|-------------|
| `LABEL_PRINT_MODE` | `mock` | `mock` (no printing) or `cups` (send to printer) |
| `LABEL_PRINTER_QUEUE` | *(empty)* | CUPS queue name (e.g., `QL800`) |
| `LABEL_OUTPUT_DIR` | `labels/` | Directory for saved label images |
| `LABEL_STOCK` | `DK1202` | Label stock type |
| `LABEL_DPI` | `300` | Rendering DPI |
| `LABEL_ORIENTATION` | `landscape` | `landscape` or `portrait` |
| `LABEL_QR_PAYLOAD_MODE` | `url` | `url` (staff page link) or `id` (Print ID only) |
| `LABEL_QR_SIZE_INCH` | `0.5` | QR code size on label |
| `LABEL_CUPS_MEDIA` | `DK-1202` | CUPS media identifier |
| `LABEL_CUPS_EXTRA_OPTIONS` | *(empty)* | Comma-separated extra `lp -o` options |
| `LABEL_SAVE_LABEL_FILES` | `true` | Save label PNGs for reprint/preview |
| `LABEL_BRAND_TEXT` | `NC State University Libraries Makerspace` | Text at top of label |
| `LABEL_BRAND_LOGO_PATH` | *(empty)* | Path to logo PNG for label header |

### Email

| Variable | Default | Description |
|----------|---------|-------------|
| `EMAIL_PROVIDER` | `smtp` | `smtp`, `gmail_api`, or `auto` |
| `SMTP_HOST` | *(empty)* | SMTP server hostname |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USERNAME` | *(empty)* | SMTP username |
| `SMTP_PASSWORD` | *(empty)* | SMTP password |
| `SMTP_USE_TLS` | `true` | Enable STARTTLS |
| `SMTP_FROM_ADDRESS` | `makerspace@example.com` | Sender address for SMTP |

### Google OAuth + Sheets

| Variable | Default | Description |
|----------|---------|-------------|
| `GOOGLE_OAUTH_CLIENT_ID` | *(empty)* | OAuth client ID |
| `GOOGLE_OAUTH_CLIENT_SECRET` | *(empty)* | OAuth client secret |
| `GOOGLE_OAUTH_REFRESH_TOKEN` | *(empty)* | OAuth refresh token (from bootstrap script) |
| `GOOGLE_OAUTH_TOKEN_URI` | `https://oauth2.googleapis.com/token` | Token endpoint |
| `GOOGLE_GMAIL_SENDER` | *(empty)* | Gmail API sender address |
| `GOOGLE_SHEETS_SYNC_ENABLED` | `false` | Enable Google Sheets sync |
| `GOOGLE_SHEETS_SPREADSHEET_ID` | *(empty)* | Target spreadsheet ID |
| `GOOGLE_SHEETS_WORKSHEET` | `PrintJobs` | Worksheet tab name |

---

## 8) Staff Runtime Settings

Settings are stored in the database and take effect immediately:

| Setting | Description |
|---------|-------------|
| Completion email | Enable/disable patron notification emails |
| Save label files | Keep rendered label PNGs for reprint and preview |
| Label retention days | How many days to keep saved labels (1–30) |
| QR payload mode | `url` for phone camera scanning, `id` for USB barcode scanner |

---

## 9) Troubleshooting

### Label preview shows 404

Label saving is disabled in staff settings, or the label file was cleaned
up. Enable saving and reprint.

### QR scan opens wrong or unreachable URL

`KIOSK_BASE_URL` doesn't match the tunnel URL, or the tunnel is down.
Verify with `sudo systemctl status cloudflared`.

### `sqlite3.OperationalError: unable to open database file`

Check that `DATABASE_URL` uses an absolute path and the service user can
write to the database directory.

### Google Sheets sync fails

- Confirm the spreadsheet ID and worksheet name in `.env`
- Confirm the OAuth account has edit access to the spreadsheet
- Check logs: `journalctl -u print-tracker -f`

### Cloudflare Tunnel won't connect

- Check `sudo systemctl status cloudflared`
- The Pi needs outbound HTTPS access (port 443). Campus networks rarely
  block this.
- Re-authenticate if the cert expired: `cloudflared tunnel login`

### `chromium-browser has no installation candidate`

Deploy script auto-detects the correct package name. Pull latest code and
rerun deploy.

### Corrupted virtualenv

```bash
sudo systemctl stop print-tracker || true
rm -rf .venv
./scripts/deploy_rpi.sh
```

---

## 10) Useful Commands

```bash
# App service
sudo systemctl status print-tracker --no-pager
sudo systemctl restart print-tracker
journalctl -u print-tracker -f

# Cloudflare Tunnel
sudo systemctl status cloudflared --no-pager
sudo systemctl restart cloudflared
journalctl -u cloudflared -f

# CUPS
lpstat -e                 # list queues
lpstat -p -d              # printer status
lp -d QL800 /usr/share/cups/data/testprint   # test print
```

---

## Architecture Roadmap

### Current: Pi-only MVP

Each location runs its own Pi with the full Flask app, SQLite, CUPS, and
a Cloudflare Tunnel for public HTTPS access. Google Sheets is the
shared external record. This requires zero IT involvement.

### Future: Server + Pi print relays

When ready for IT investment:

| MVP (now) | Production (later) |
|-----------|-------------------|
| Flask runs on each Pi | Flask moves to a university server |
| Cloudflare Tunnel provides HTTPS | nginx + TLS on server |
| CUPS is local to the Pi | Pi becomes a thin print agent (polling) |
| SQLite per-Pi | SQLite on server (single instance) |
| Separate instances per location | One instance with location selector |
| Separate Sheets tabs/columns | One tab with a Location column |

The migration path:

1. Deploy the Flask app on a university VM with a real hostname and TLS
2. Add a `/api` blueprint for print-agent polling
3. Each Pi runs a lightweight `print_agent.py` that polls the server for
   pending labels, downloads the PNG, and sends it to local CUPS
4. Add a `location` field to the data model and a location picker on the
   registration form
5. One Google Sheet, one URL, one dashboard for all locations
