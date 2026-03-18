# Print Tracker

Print Tracker is a Flask app for managing 3D-print jobs across NC State
University Libraries makerspaces (Makerspace and Maker Studio).

## Team Overview (Paste Into Google Doc)

Print Tracker replaces paper-based 3D print sign-up and completion tracking
with a phone-first workflow. Patrons register prints from their phones,
staff complete jobs by scanning a QR code on printed labels, and the system
handles notification emails plus optional Google Sheets sync. The app runs on
a Raspberry Pi with a Brother label printer and can publish a stable public
URL through a Cloudflare named tunnel. Day-to-day operations are designed for
non-developers: install/update via guided installer, simple staff dashboard,
and monthly reporting exports.

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

### Proof of Concept (current fork direction)

The current implementation work is moving toward a split architecture proof
of concept:

```text
MacBook on LAN
   Docker app + PostgreSQL
   http://<mac-ip>:5000/makerspace
               |
               | HTTP polling
               v
Raspberry Pi agent
   scripts/pi_worker.py
   CUPS -> Brother QL-800
```

This POC uses path-based spaces from the start so the same URLs can later
move to a stable host such as `print-tracker.experiment.lib.ncsu.edu`
without changing route structure.

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
- Optional side-art watermark from `LABEL_SIDE_ART_PATH` (PNG or SVG)
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

### 2.1 Docker POC start

For the server/agent proof of concept, you can run the server locally in
Docker with PostgreSQL:

```bash
cp .env.example .env
docker compose up --build
```

Important POC settings:
- Set `KIOSK_BASE_URL` to your Mac's LAN IP, for example
   `http://192.168.1.50:5000`, so QR links are usable from phones and the Pi.
- Set `AGENT_BOOTSTRAP_KEY` before registering a Pi agent.
- `WORKER_DISPATCH_ENABLED=true` in `docker-compose.yml` means the server
   will queue jobs for Pi dispatch instead of printing locally.

Space-aware entry points:
- `http://<mac-ip>:5000/makerspace`
- `http://<mac-ip>:5000/maker-studio`

Pi agent API endpoints added for the POC:
- `POST /api/agents/register`
- `POST /api/agents/heartbeat`
- `GET /api/agents/jobs`
- `POST /api/agents/jobs/<label_code>/printed`
- `POST /api/agents/jobs/<label_code>/failed`

### 2.2 Raspberry Pi agent POC

The first Pi-side worker is now implemented as `scripts/pi_worker.py`.
It:

- registers with the server using a bootstrap key
- polls only for jobs assigned to its configured space
- renders and prints labels locally via the existing label printer service
- reports success or failure back to the server

Minimal setup on a Pi:

```bash
cp .env.pi-agent.example .env.pi-agent
./scripts/install_pi_agent.sh \
   --server-url http://192.168.1.50:5000 \
   --space makerspace \
   --agent-id makerspace-pi-01 \
   --bootstrap-key your-bootstrap-key \
   --printer-queue QL-800
```

You can also run the worker directly for testing:

```bash
PI_AGENT_ENV_FILE=.env.pi-agent ./.venv/bin/python scripts/pi_worker.py
```

---

## 3) Raspberry Pi Deploy (Fresh Image)

### 3.1 Recommended install path (no manual setup)

Use Raspberry Pi OS (Desktop or Lite, Bookworm or later). Plug the Pi
into wired Ethernet and connect the Brother QL-800 printer via USB.

You can install either by double-clicking a release launcher file or by
running one install command. In both paths, the installer does the rest.

Option A (recommended for non-technical users):
1. Download the latest release zip.
2. Extract it.
3. Double-click `Install PrintTracker.desktop`.

Option B (terminal command):

```bash
curl -fsSL https://raw.githubusercontent.com/ColinRNickels/printtracker/main/scripts/deploy_rpi.sh | sudo bash
```

The interactive wizard walks you through every setting (staff password,
printer, tunnel, Google integration, etc.). When it finishes the app is
live and printing.

Minimum requirements for either path:
- Internet connection
- Admin privileges (`sudo`)
- Raspberry Pi OS Bookworm or later
- `curl` (or `wget`) available to download the installer script

No separate git clone, Python setup, apt package list, or manual service
configuration is required before starting the installer.

### 3.2 What the installer handles automatically

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

### 3.3 Brother QL-800 setup (only if auto-detect fails)

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

### 3.4 Advanced examples (optional)

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

### 3.5 Build the release zip (maintainers)

From the project root:

```bash
bash scripts/package-release.sh v1.2.0
```

This creates:
- `dist/PrintTracker-v1.2.0-pi.zip`
- `dist/PrintTracker-v1.2.0-pi.zip.sha256`

Upload the zip to GitHub Releases or Google Drive for end users.

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

### 4.2 External prerequisites (account-level, not automated)

These are only needed if you want a permanent public URL. They are not
required for local-only operation.

1. **Cloudflare account** — https://dash.cloudflare.com/sign-up
2. **Domain added to Cloudflare** — `howcanthis.be` with Cloudflare
   nameservers set at the registrar
3. **cloudflared CLI on the machine creating the tunnel** (laptop or Pi)
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

If you start from `Install PrintTracker.desktop`, this step still happens
inside the same guided installer flow.

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

If you choose Google setup during `deploy_rpi.sh`, the installer will guide
you through this. The steps below are for manual or recovery setup.

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
| `LABEL_SIDE_ART_PATH` | `assets/noun-3d-printer-8112508.svg` | Optional large background watermark image (PNG/SVG) |

### Library hours enforcement

| Variable | Default | Description |
|----------|---------|-------------|
| `LIBRARY_HOURS_ENFORCE` | `true` | Enforce open-hours checks on patron registration |
| `LIBRARY_HOURS_LIBRARY_SHORT_NAME` | `hill` | API `library_short_name` value to match |
| `LIBRARY_HOURS_SERVICE_SHORT_NAME` | `makerspace` | API `service_short_name` value to match |
| `LIBRARY_HOURS_POST_CLOSE_BUFFER_MINUTES` | `10` | Grace period after closing before submissions are blocked |

Notes:
- Staff sessions (`/staff` login) bypass hours checks for assisted/testing registrations.
- Date matching uses NC local time (`America/New_York`) to align with the hours API date field.

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

### Registration still works when space should be closed

Check these first:
- `LIBRARY_HOURS_ENFORCE=true` in `.env`.
- `LIBRARY_HOURS_LIBRARY_SHORT_NAME` and `LIBRARY_HOURS_SERVICE_SHORT_NAME`
   match API values for your location.
- You are not currently staff-authenticated in that browser session
   (`/staff` login bypasses hours checks by design).

Debug command:

```bash
journalctl -u print-tracker -f
```

### Label says generated but nothing physically prints

Most common causes:
- `LABEL_PRINT_MODE=mock` (intended for testing; does not send to printer).
- `LABEL_PRINTER_QUEUE` doesn't match the real CUPS queue name.
- Printer is offline/out of labels or queue is paused.

Checks:

```bash
grep -E '^LABEL_PRINT_MODE=|^LABEL_PRINTER_QUEUE=' .env
lpstat -e
lpstat -p -d
lp -d QL-800 /usr/share/cups/data/testprint
```

### Labels render but are missing logo/side-art

Check asset paths in `.env`:
- `LABEL_BRAND_LOGO_PATH` for header logo.
- `LABEL_SIDE_ART_PATH` for watermark (PNG or SVG).

If files are missing on disk, label generation falls back gracefully and
continues without those assets.

### Label preview shows 404

Label saving is disabled in staff runtime settings, or the label file was
cleaned by retention policy. Enable saving, then reprint.

### QR scan opens wrong or unreachable URL

`KIOSK_BASE_URL` in `.env` must match your live hostname:
`https://<hostname>` (for example, `https://hill-print.howcanthis.be`).

Checks:

```bash
grep '^KIOSK_BASE_URL=' .env
sudo systemctl status cloudflared --no-pager
```

### App is up locally but unreachable from phones

Potential causes:
- Cloudflare tunnel service is down.
- Tunnel hostname or DNS route is wrong.
- Device is off campus Wi-Fi or has captive portal issues.

Checks:

```bash
sudo systemctl status cloudflared --no-pager
journalctl -u cloudflared -n 120 --no-pager
```

### Staff login/access problems

- Confirm `STAFF_PASSWORD` in `.env` is what staff are entering.
- Restart app after changing `.env`: `sudo systemctl restart print-tracker`.
- Clear stale browser session/cookies if login state looks inconsistent.

### `sqlite3.OperationalError: unable to open database file`

`DATABASE_URL` should point to a writable absolute path, and the service
user must have permission to that directory.

### Google Sheets sync fails

Check:
- `GOOGLE_SHEETS_SYNC_ENABLED=true`.
- Correct spreadsheet ID and worksheet in `.env`.
- OAuth account has edit access to the sheet.
- Refresh token is valid.

Logs:

```bash
journalctl -u print-tracker -f
```

### Email notifications fail

If using Gmail API:
- Verify OAuth values and `GOOGLE_GMAIL_SENDER`.

If using SMTP:
- Verify `SMTP_HOST`, `SMTP_PORT`, credentials, and TLS setting.

Check logs for provider-specific exceptions:

```bash
journalctl -u print-tracker -f
```

### Cloudflare Tunnel won't connect

- Check `sudo systemctl status cloudflared`.
- Pi needs outbound HTTPS access (port 443).
- Re-authenticate tunnel if cert/token expired: `cloudflared tunnel login`.

### `chromium-browser has no installation candidate`

Deploy script auto-detects the right package name. Pull latest code and
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
