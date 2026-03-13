# Print Tracker Handoff

## Snapshot

- Date: 2026-03-13
- Repo: `/Users/crnickel/Dev/Print Tracker`
- Remote: `https://github.com/ColinRNickels/printtracker.git`
- Python: 3.12+ with venv at `.venv/`

## Product Summary

Flask-based 3D-print tracking system for NC State University Libraries
makerspaces (Makerspace and Maker Studio). Phone-first design — patrons
register prints on their own phones via a QR code poster, and staff
complete jobs by scanning the label QR from their phones.

Data lives in SQLite (fast local operations, WAL mode) with Google Sheets
as the durable external record. Email notifications go through the Gmail
API (with SMTP fallback). A Cloudflare named tunnel provides public HTTPS
with a permanent hostname so students on campus Wi-Fi can reach the Pi
without IT involvement. go.ncsu.edu short links give each location a
stable, memorable URL.

## Project Goals

1. **Replace paper-based print tracking** — eliminate the hand-written
   sign-up sheets and sticky notes currently used to manage 3D-print
   queues in the makerspaces.
2. **Self-service patron registration** — let patrons register their own
   prints from their phones so staff don't have to be present at every
   printer when a job starts.
3. **Automated patron notification** — email patrons when their print is
   finished (or failed) so they know when to pick it up, reducing foot
   traffic and "is my print done?" questions at the desk.
4. **Durable record in Google Sheets** — sync every print to a shared
   Google Sheet that staff and administrators can browse, filter, and
   export without touching the app.
5. **Zero IT dependency** — run the entire system on a Raspberry Pi with
   a Cloudflare tunnel so the Libraries can deploy and iterate without
   waiting on university IT for servers, DNS, or firewall changes.
6. **Multi-location readiness** — support both the Makerspace and Maker
   Studio (and future spaces) with per-location Pis today, and a path to
   a centralized server later.
7. **Reporting and accountability** — provide monthly usage reports with
   charts and CSV exports so the makerspaces can justify funding, track
   trends, and report to administrators.

## Architecture

### MVP: Pi-only with Cloudflare Tunnel

```
Student phone (campus Wi-Fi)
        │  HTTPS
        ▼
┌──────────────────────────────┐
│  go.ncsu.edu/makerspace-…   │  ← stable short link
│  → hill-print.howcanthis.be  │  ← Cloudflare named tunnel
│     hunt-print.howcanthis.be │
└──────────┬───────────────────┘
           │  localhost:5000
           ▼
┌──────────────────────────────┐
│  Raspberry Pi                │
│  Flask + gunicorn (systemd)  │
│  SQLite (WAL mode)           │
│  CUPS → Brother QL-800       │
│  Gmail API + Sheets sync     │
└──────────────────────────────┘
```

Each makerspace location runs its own Pi + named tunnel. The campus
network has client isolation enabled, so direct Pi-to-phone routing is
not possible without the tunnel.

Domain: `howcanthis.be` (Cloudflare-managed DNS)
- `hill-print.howcanthis.be` → Hill Library Pi
- `hunt-print.howcanthis.be` → Hunt Library Pi

Systemd services:
- `print-tracker` — gunicorn on `0.0.0.0:5000`
- `cloudflared` — named tunnel via `/etc/cloudflared/config.yml`

### Future: server + Pi print relays

Flask app moves to a university server. Each Pi becomes a lightweight
print agent that polls the server for pending labels. A location picker
replaces the per-Pi config. One instance, one URL, one Google Sheet.

## App Structure

### Startup

- `run.py` → `create_app()` in `print_tracker/__init__.py`
- Loads `.env`, normalizes paths (DB URI, label dir, logo path)
- Creates DB tables + runs `_apply_schema_upgrades()` (adds missing
  `department`, `pi_name`, `location` columns)
- SQLite WAL mode enabled on every connection via `engine.connect()` event

### Data model (`print_tracker/models.py`)

**PrintJob** fields:
- `label_code` (unique, indexed) — format `{SITE_ID}-YYYYMMDD-HHMMSS-##`
- Patron: `user_name`, `user_email`, `print_title`
- Category: `personal_project` | `course_assignment` | `university_research`
  - Course-specific: `course_number`, `instructor`
  - Research-specific: `department`, `pi_name`
- Location: `location`, `printer_name` (both from `DEFAULT_PRINTER_NAME`)
- Status: `in_progress` → `finished` | `failed`
- Timestamps: `created_at`, `completed_at`, `email_sent_at` (all TZ-aware UTC)
- Completion: `completed_by`, `completion_notes`
- Email: `email_status` (`not_attempted`/`sent`/`failed`/`skipped`), `email_error`
- Other: `notes`, `estimated_minutes`

**AppSetting** — runtime key/value toggles (no restart needed):
- `completion_email_enabled`, `save_label_files`, `label_retention_days`,
  `qr_payload_mode`

### Routes

| Blueprint | Prefix | File | Purpose |
|-----------|--------|------|---------|
| `patron` | `/patron` | `routes/patron.py` | Registration form, QR images, label preview |
| `staff` | `/staff` | `routes/staff.py` | Login, dashboard, scan, completion, reprint, settings |
| `reports` | `/reports` | `routes/reports.py` | Monthly report page + CSV export |

Key route details:
- `GET /` redirects to `/patron/register`
- `GET /kiosk/*` 301-redirects to `/patron/*` (backward compat for old QR codes)
- `POST /staff/login` rate-limited (10/min via Flask-Limiter)
- `GET /staff/s/<code>` — short scan route (redirects to completion page)
- `POST /staff/scan` — extracts label code from full URL or bare input
- Staff auth via session cookie; before-request hook redirects to login

### Services

| Module | Purpose |
|--------|---------|
| `label_printer.py` | PIL label rendering + CUPS print; `cleanup_saved_labels()` by retention age |
| `runtime_settings.py` | Read/write `AppSetting` toggles; `get_bool_setting()`, `get_int_setting()`, `get_choice_setting()` |
| `notifier.py` | Email via Gmail API / SMTP / auto-fallback; HTML+plaintext templates with embedded logo |
| `google_api.py` | `build_google_service()` — refresh-token OAuth for Gmail + Sheets |
| `sheets_sync.py` | Append/update rows in Google Sheets (21-column schema, auto-headers, upsert by PrintID) |
| `reports.py` | `build_monthly_summary()`, chart datasets (trend, pie, department bar) |
| `qr_links.py` | `build_staff_completion_url()` using `KIOSK_BASE_URL` or request context |

### Templates

| File | Surface |
|------|---------|
| `base.html` | Shared layout — nav hidden on patron routes |
| `patron_register.html` | Patron registration form (conditional course/research fields) |
| `patron_success.html` | Post-registration success with physical next steps, 10 s auto-return |
| `staff_login.html` | Password gate |
| `staff_dashboard.html` | In-progress + completed job cards, settings form, QR mode warning |
| `staff_complete.html` | Mark Finished / Failed (inline confirm, failure notes required) |
| `reports_monthly.html` | Month picker, 4 Chart.js charts, summary stats, CSV export |
| `email_success.*` / `email_failure.*` | `.html` + `.txt` notification templates |

### CSS (`print_tracker/static/app.css`)

Mobile-first responsive design:
- Base styles = phone portrait (single-column, 48 px+ touch targets)
- `@media (min-width: 768px)` = laptop (two-column grids, three-column
  type cards, 12-column chart grid)

## Config (`print_tracker/config.py`)

All configuration via environment variables loaded from `.env`.  
Reference: `.env.example` (36 variables).

| Variable | Default | Notes |
|----------|---------|-------|
| `SECRET_KEY` | `change-me` | Flask session key |
| `DATABASE_URL` | `sqlite:///instance/print_tracker.db` | |
| `STAFF_PASSWORD` | `staffpw` | Hashed at startup |
| `LABEL_PRINT_MODE` | `mock` | `mock` or `cups` |
| `LABEL_PRINTER_QUEUE` | (empty) | CUPS queue name e.g. `QL800` |
| `LABEL_OUTPUT_DIR` | `labels` | Saved label PNGs |
| `KIOSK_BASE_URL` | `http://localhost:5000` | Public URL for QR payloads; auto-updated by tunnel script |
| `LABEL_STOCK` | `DK1202` | Brother label stock |
| `LABEL_DPI` | `300` | |
| `LABEL_ORIENTATION` | `landscape` | |
| `LABEL_QR_PAYLOAD_MODE` | `url` | `url` (full link) or `id` (bare code) |
| `LABEL_QR_SIZE_INCH` | `1.0` | |
| `LABEL_BRAND_TEXT` | `NC State University Libraries Makerspace` | |
| `LABEL_BRAND_LOGO_PATH` | (empty) | Optional PNG; auto-converted to 1-bit |
| `LABEL_CUPS_MEDIA` | `DK-1202` | |
| `LABEL_CUPS_EXTRA_OPTIONS` | (empty) | |
| `LABEL_SAVE_LABEL_FILES` | `true` | |
| `EMAIL_PROVIDER` | `smtp` | `smtp`, `gmail_api`, or `auto` |
| `SMTP_HOST`…`SMTP_FROM_ADDRESS` | | Standard SMTP settings |
| `GOOGLE_OAUTH_CLIENT_ID` | | OAuth 2.0 credentials |
| `GOOGLE_OAUTH_CLIENT_SECRET` | | |
| `GOOGLE_OAUTH_REFRESH_TOKEN` | | From bootstrap script |
| `GOOGLE_OAUTH_TOKEN_URI` | `https://oauth2.googleapis.com/token` | |
| `GOOGLE_GMAIL_SENDER` | | Gmail sending address |
| `GOOGLE_SHEETS_SYNC_ENABLED` | `false` | |
| `GOOGLE_SHEETS_SPREADSHEET_ID` | | Accepts full URL or bare ID |
| `GOOGLE_SHEETS_WORKSHEET` | `PrintJobs` | |
| `DEFAULT_PRINTER_NAME` | `Makerspace` | Location name in Sheets + labels |
| `SITE_ID` | (empty) | 2–4 letter prefix for label codes (e.g. `HL`, `HU`; default `PT`) |
| `TUNNEL_HOSTNAME` | (empty) | Permanent tunnel hostname (e.g. `hill-print.howcanthis.be`) |
| `GO_NCSU_API_TOKEN` | | API token for go.ncsu.edu |
| `GO_NCSU_LINK_SLUG` | `makerspace-print-label` | Short link slug |

Session cookies: `Secure`, `HttpOnly`, `SameSite=Lax`.

## Google Sheets Sync

- Sync on both registration and completion (upsert by PrintID)
- Headers (21 columns): PrintID, CreatedAt, CompletedAt, Status,
  StatusLabel, ProjectType, ProjectTypeLabel, FileName, UserName,
  UserEmail, CourseNumber, Instructor, Department, PI, CompletedBy,
  CompletionNotes, EmailStatus, EmailError, EmailSentAt, PrinterName,
  **Location**
- Location value comes from `DEFAULT_PRINTER_NAME` config
- Sheet and headers are created automatically on first sync

## Deploy

### Pi deploy

```bash
./scripts/deploy_rpi.sh
```

Interactive TUI wizard (~1 700 lines) with 8 steps:

1. Staff password (prompted with confirmation)
2. Linux service user/group/port
3. Label printer mode (`cups`/`mock`) + CUPS queue + media
4. Location name & Site ID
5. Cloudflare named tunnel (optional — creds file path + hostname)
6. go.ncsu.edu short link (optional)
7. Google OAuth (optional — runs bootstrap flow)
8. Review & confirm

Non-interactive mode: `./scripts/deploy_rpi.sh --non-interactive`  
Also accepts `--print-mode`, `--tunnel-creds-file PATH`,
`--tunnel-hostname HOST`, `--no-ap`, `--no-kiosk-autostart`, etc.

Installs: apt packages (`cups`, `printer-driver-ptouch`, `avahi-daemon`,
`usbutils`, `cloudflared`), Python venv + requirements + gunicorn,
generates `.env`, creates systemd units, optionally runs OAuth flow.

Named tunnel setup (Step 5 / Section 9):
- Prompts for tunnel credentials JSON file and hostname
- Auto-detects creds on USB transfer drive (`/media/`), `/etc/cloudflared/`, or `~/.cloudflared/`
- Copies creds to `/etc/cloudflared/tunnel-creds.json`
- Writes `/etc/cloudflared/config.yml` with extracted TunnelID
- Runs `cloudflared service install` and verifies the service
- Cleans up any legacy `cloudflared-quick` service from MVP

### Cloudflare Tunnel

Named tunnels with permanent hostnames (replaces the MVP quick-tunnel
approach). Each Pi has:

- `/etc/cloudflared/config.yml` — tunnel ID, credentials path, ingress
  rules routing the hostname to `http://localhost:5000`
- `/etc/cloudflared/tunnel-creds.json` — tunnel credentials JSON
- `cloudflared` systemd service (installed via `cloudflared service install`)

The tunnel URL never changes, so `KIOSK_BASE_URL` in `.env` is set once
at deploy time (`https://<hostname>`) and go.ncsu.edu only needs to be
updated once.

Legacy scripts (kept for dev/testing, no longer used in production):
- `scripts/start_tunnel.sh` — quick tunnel manager (was `cloudflared-quick` service)
- `scripts/get_tunnel_url.sh` — prints current URL from journalctl / .env

Helper scripts:
- `scripts/update_golink.sh` — manually update go.ncsu.edu link

### Google OAuth bootstrap

Run on a machine with a browser:

```bash
python scripts/google_oauth_bootstrap.py \
  --client-secrets ~/Downloads/client_secret.json \
  --gmail-sender makerspace@ncsu.edu
```

Copy the printed env values into the Pi's `.env`.

## Key Design Decisions

1. **Phone-first architecture** — Cloudflare Tunnel for HTTPS; responsive
   mobile-first CSS; nav hidden on patron routes; card-based staff
   dashboard; 48 px+ touch targets; `viewport-fit=cover` for notched phones.

2. **Multi-location support** — `DEFAULT_PRINTER_NAME` doubles as
   location name; `SITE_ID` prefixes label codes per site; `location`
   column on `PrintJob` and in Sheets. MVP: one Pi per location.

3. **go.ncsu.edu short links** — Named tunnels have permanent URLs, so
   the go link only needs to be set once. Legacy quick-tunnel workflow
   (`start_tunnel.sh`) auto-patched the go link on each restart.

4. **SQLite WAL mode** — Enabled per-connection via SQLAlchemy event
   listener for better concurrent read performance.

5. **Timezone-aware datetimes** — All timestamps use
   `datetime.now(timezone.utc)`.

6. **DRY label printing** — `build_label_kwargs(job)` in `routes/patron.py`
   shared between registration and reprint.

7. **Email auto-fallback** — `EMAIL_PROVIDER=auto` tries Gmail API first,
   falls back to SMTP.

8. **Runtime settings in DB** — Staff can toggle email, label saving,
   retention days, QR mode without restarting the app.

9. **Schema migrations at startup** — `_apply_schema_upgrades()` adds
   missing columns (`department`, `pi_name`, `location`) so upgrades
   don't require manual SQL.

10. **Security** — CSRF tokens (Flask-WTF), password hashing (Werkzeug),
    session cookie hardening, rate limiting on login (Flask-Limiter),
    NCSU email domain validation, path normalization.

6. **README rewrite**
   - Full deployment docs: Pi setup, Cloudflare Tunnel, Google OAuth
   - Architecture diagram and roadmap
   - Configuration reference tables
   - Troubleshooting guide

## Known Risks / Follow-up Ideas

- **No migration framework**: Schema upgrades are manual `ALTER TABLE` in
  `_apply_schema_upgrades()`. Consider Flask-Migrate when schema changes
  become frequent.
- **`STAFF_PASSWORD` plain text**: Acceptable for MVP. Move to hashed
  auth or SSO for hardening.
- **Credentials in shell history**: AP and OAuth values passed via CLI
  flags may end up in shell history.
- **Deploy script still has AP/kiosk options**: These work but are not
  needed for the phone-first workflow. Pass `--no-ap --no-kiosk-autostart`
  to skip.
- **Single-Pi reliability**: No redundancy. If the Pi dies, prints are
  tracked only in Google Sheets until a replacement is set up. Keep an
  SD card image backup. Consider protecting SD cards with a read-only
  overlay or using a USB SSD.
- **OAuth token expiry**: Google refresh tokens can expire if unused for
  6 months or if the OAuth app is in "testing" mode (7-day expiry).
  Publish the app or use a Workspace account for long-lived tokens.
- **No health endpoint**: Consider adding a `/health` route and
  UptimeRobot (or similar) monitoring for each tunnel hostname.

## Quick Validation Checklist

After pulling latest code:

1. `bash -n scripts/deploy_rpi.sh`
2. `source .venv/bin/activate && python -m compileall -q print_tracker`
3. Start app, verify:
   - patron registration form loads
   - large text appearance
   - label print path
   - QR scan on phone -> login -> correct print completion page
   - staff settings save
   - reports charts render

## Suggested Next Agent First Steps

1. Run end-to-end test on real Pi hardware:
   - QR scan/login/complete flow via named tunnel hostname
   - physical Brother label print
2. Validate Google OAuth + Sheets write on Pi (real account).
3. Set up Cloudflare Access policies to restrict tunnel access to NCSU networks.
4. Move Google OAuth app out of "Testing" mode to avoid 7-day token expiry.
5. Add a `/health` endpoint and configure UptimeRobot for each Pi.
