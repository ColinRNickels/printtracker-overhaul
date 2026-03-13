# Print Tracker

Print Tracker is a Flask app for managing 3D-print jobs across NC State
University Libraries makerspaces (Makerspace and Maker Studio).

## Goals

1. **Replace paper-based print tracking** — eliminate hand-written sign-up
   sheets and sticky notes currently used to manage 3D-print queues.
2. **Self-service patron registration** — patrons register prints from
   their phones so staff don't need to be present at every printer.
3. **Automated patron notification** — email patrons when prints finish
   (or fail) so they know when to pick up, reducing desk questions.
4. **Durable record in Google Sheets** — every print syncs to a shared
   Sheet that staff and administrators can browse and export directly.
5. **Zero IT dependency** — runs on a Raspberry Pi with a Cloudflare
   tunnel; no servers, DNS changes, or firewall requests needed.
6. **Multi-location readiness** — supports multiple makerspaces today
   (one Pi each) with a path to a centralized server later.
7. **Reporting and accountability** — monthly usage reports with charts
   and CSV exports for funding justification and trend tracking.

---

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
│  Cloudflare Named Tunnel     │
│  hill-print.howcanthis.be    │
│  hunt-print.howcanthis.be    │
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

Each makerspace location runs its own Pi with a named Cloudflare tunnel
and a permanent hostname under `howcanthis.be`. Students on campus Wi-Fi
reach the Pi via HTTPS — no IT firewall changes, no DNS requests, no
server provisioning. The tunnel URL never changes, so QR code posters and
go.ncsu.edu short links only need to be set up once.

### Production (future — server + Pi print relays)

When ready for IT involvement, the Flask app moves to a university server.
Each Pi becomes a lightweight print agent that polls the server for pending
labels. See [Architecture Roadmap](#architecture-roadmap) at the end of
this document.

---

## 1) What's Implemented

### Registration form (`/patron/register`)

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

- Register: `http://localhost:5000/patron/register`
- Staff: `http://localhost:5000/staff/`
- Reports: `http://localhost:5000/reports/monthly`

If port 5000 is busy:

```bash
PORT=5050 python run.py
```

---

## 3) Raspberry Pi Deploy (Fresh Image)

### 3.1 One-time setup

Use Raspberry Pi OS (Desktop or Lite, Bookworm or later). Plug the Pi
into wired Ethernet and connect the Brother QL-800 printer via USB.

**One command does everything:**

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/ColinRNickels/printtracker.git ~/PrintTracker
cd ~/PrintTracker
sudo ./scripts/deploy_rpi.sh
```

The interactive wizard walks you through every setting (staff password,
printer, tunnel, Google integration, etc.). When it finishes the app is
live and printing.

### 3.2 What the deploy script does

`scripts/deploy_rpi.sh` automates:

- System packages (`cups`, `printer-driver-ptouch`, `cloudflared`,
  `curl`, `fonts-dejavu-core`, etc.)
- Python virtualenv + dependencies
- `.env` creation/update with all settings
- Database initialization
- CUPS printer queue auto-creation (if a Brother USB printer is detected)
- systemd services (`print-tracker` + optional `cloudflared` named tunnel)
- File ownership (so the service user can write to the DB and labels dir)
- Optional Cloudflare named tunnel for public HTTPS access (creds file +
  hostname → writes `/etc/cloudflared/config.yml`, runs
  `cloudflared service install`)
- Cleans up legacy `cloudflared-quick` service if present
- Optional go.ncsu.edu short link
- Optional Google OAuth setup (Gmail notifications + Sheets sync)

### 3.3 Brother QL-800 setup (CUPS)

The deploy script auto-creates the CUPS printer queue if it detects a
Brother USB device. If the printer is not plugged in during deploy, or
auto-detection fails, you can set it up manually:

1. Plug in QL-800 via USB.
2. Open `http://localhost:631`.
3. Administration → Add Printer.
4. Select the Brother device and driver.
5. Set the queue name to match `.env` (default `QL-800`).

Verify:

```bash
lpstat -e
lpstat -p -d
lp -d QL-800 /usr/share/cups/data/testprint
```

### 3.4 Deploy script examples

```bash
# Accept all defaults (interactive wizard)
sudo ./scripts/deploy_rpi.sh

# Non-interactive with defaults
sudo ./scripts/deploy_rpi.sh --non-interactive --staff-password 'YourPassword'

# Development/testing without a printer
sudo ./scripts/deploy_rpi.sh --print-mode mock

# With named tunnel (creds file + hostname)
sudo ./scripts/deploy_rpi.sh \
  --tunnel-creds-file ~/.cloudflared/<TUNNEL_ID>.json \
  --tunnel-hostname hill-print.howcanthis.be

# Full Google OAuth setup
sudo ./scripts/deploy_rpi.sh \
  --setup-google-oauth \
  --google-client-secrets ~/Downloads/client_secret.json \
  --google-gmail-sender makerspace@ncsu.edu \
  --google-spreadsheet-id <SHEET_ID>
```

---

## 4) Cloudflare Tunnel Setup

Cloudflare named tunnels give each Pi a permanent public HTTPS URL so
students on campus Wi-Fi can reach the registration form on their phones.
Free tier. Domain: `howcanthis.be` (Cloudflare-managed DNS).

Current hostnames:
- `hill-print.howcanthis.be` → Hill Library Pi
- `hunt-print.howcanthis.be` → Hunt Library Pi

### 4.1 Quick test (no account needed)

For development or demos, a temporary quick tunnel works without any
account or domain:

```bash
cloudflared tunnel --url http://localhost:5000
```

It prints something like `https://random-words-here.trycloudflare.com`.
The URL changes on every restart — fine for testing, not for production.

### 4.2 Prerequisites (one-time, on your laptop)

1. **Cloudflare account** — https://dash.cloudflare.com/sign-up
2. **Domain added to Cloudflare** — `howcanthis.be` with Cloudflare
   nameservers set at the registrar
3. **cloudflared installed** — `brew install cloudflared` (macOS) or
   download the `.deb` for the Pi
4. **Authenticate** — `cloudflared tunnel login` (opens browser, saves
   `~/.cloudflared/cert.pem`)

### 4.3 Create a named tunnel

```bash
# Create tunnel (generates credentials JSON)
cloudflared tunnel create hill-print

# Route a hostname to it (creates CNAME in Cloudflare DNS)
cloudflared tunnel route dns hill-print hill-print.howcanthis.be
```

Note the tunnel ID (e.g., `abcd-1234-efgh-5678`). A credentials file is
created at `~/.cloudflared/<TUNNEL_ID>.json`.

Repeat for each location:

```bash
cloudflared tunnel create hunt-print
cloudflared tunnel route dns hunt-print hunt-print.howcanthis.be
```

### 4.4 Deploy to the Pi

Copy the credentials JSON onto the USB transfer drive, plug it into the
Pi, then run the deploy script:

```bash
sudo ./scripts/deploy_rpi.sh \
  --tunnel-creds-file /media/pi/TRANSFER/tunnel-creds.json \
  --tunnel-hostname hill-print.howcanthis.be
```

Or let the interactive wizard prompt for these values in Step 5 — it
auto-detects credential files on the transfer drive.

The deploy script:
1. Copies the creds file to `/etc/cloudflared/tunnel-creds.json`
2. Extracts the tunnel ID from the JSON
3. Writes `/etc/cloudflared/config.yml`
4. Runs `cloudflared service install`
5. Verifies the `cloudflared` systemd service is active
6. Sets `KIOSK_BASE_URL=https://<hostname>` in `.env`

The tunnel starts on boot and reconnects automatically after network
interruptions. The URL never changes.

### 4.5 Cloudflare Access (optional)

To restrict access to NCSU networks:

1. Go to Cloudflare Zero Trust → Access → Applications
2. Add an application for `*.howcanthis.be`
3. Create a policy (e.g., allow NCSU IP ranges, or use email OTP)
4. The `/patron/register` path can be excluded from the policy so
   students don't need to authenticate

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
| `/patron/register` | Patron registration form |
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
| `KIOSK_BASE_URL` | `http://localhost:5000` | Public base URL for QR codes (auto-set to `https://<hostname>` by deploy script when tunnel is configured) |
| `TUNNEL_HOSTNAME` | *(empty)* | Permanent tunnel hostname (e.g., `hill-print.howcanthis.be`) |

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

`KIOSK_BASE_URL` in `.env` doesn't match the tunnel hostname. Should be
`https://<hostname>` (e.g., `https://hill-print.howcanthis.be`). Verify
the tunnel is running with `sudo systemctl status cloudflared`.

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
cat /etc/cloudflared/config.yml

# CUPS
lpstat -e                 # list queues
lpstat -p -d              # printer status
lp -d QL800 /usr/share/cups/data/testprint   # test print
```

---

## Architecture Roadmap

### Current: Pi-only MVP

Each location runs its own Pi with the full Flask app, SQLite, CUPS, and
a named Cloudflare Tunnel for permanent public HTTPS access. Google
Sheets is the shared external record. This requires zero IT involvement.

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
