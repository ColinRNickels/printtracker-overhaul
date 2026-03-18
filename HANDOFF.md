# Print Tracker Overhaul Handoff

## Snapshot

- Date: 2026-03-18
- Repo: `/Users/crnickel/Dev/Print Tracker`
- Current commit: `ec28aa0`
- Overhaul remote: `https://github.com/ColinRNickels/printtracker-overhaul.git`
- Upstream reference remote: `https://github.com/ColinRNickels/printtracker.git`
- Branch workflow: local `main` tracks `origin/main`
- Python: project venv at `.venv/`

## Current Goal

This repo is now the hard-forked overhaul proof of concept for a split
architecture:

1. Central server handles intake, staff UI, reporting, and central job state.
2. Raspberry Pi agents handle local label printing only.
3. Space-based routing is path-first from the beginning:
   - `/makerspace`
   - `/maker-studio`

The current milestone is complete enough to prove the server/agent contract
locally. The next milestone is better operator visibility and control from
the server UI.

## What Is Implemented

### Hard-fork repo setup

- GitHub cannot create a true fork under the same owner as the original repo,
  so a separate repo was created instead:
  `ColinRNickels/printtracker-overhaul`
- Remotes are now:
  - `origin` -> overhaul repo
  - `upstream` -> original repo

### Server/agent proof-of-concept foundation

- Added space-aware server routing:
  - `/<space_slug>`
  - `/<space_slug>/register`
  - `/<space_slug>/staff`
  - `/<space_slug>/staff/s/<label_code>`
- Added worker registration and polling API:
  - `POST /api/agents/register`
  - `POST /api/agents/heartbeat`
  - `GET /api/agents/jobs`
  - `POST /api/agents/jobs/<label_code>/printed`
  - `POST /api/agents/jobs/<label_code>/failed`
- Added worker model + print-dispatch state to `PrintJob`
- Added local Docker assets and local Pi worker script

### Pi worker and installer

- Added `scripts/pi_worker.py`
- Added `scripts/install_pi_agent.sh`
- Added `.env.pi-agent.example`

The worker:

1. registers with the server using a bootstrap key
2. polls for jobs only in its assigned space
3. prints locally via CUPS / Brother queue
4. reports success or failure back to the server

### Space slug compatibility fix

The server now accepts more flexible space values during agent registration.
These forms were verified to register successfully:

- `makerspace`
- `maker-studio`
- `maker studio`
- `maker_studio`
- `Maker Studio`

This fix is included in commit `ec28aa0`.

## Current Runtime State

### Local server

The server has been run locally from the venv on port `5050` for testing.

Important local environment used during testing:

- `WORKER_DISPATCH_ENABLED=true`
- `LIBRARY_HOURS_ENFORCE=false`
- `PORT=5050`
- `AGENT_BOOTSTRAP_KEY=poc-bootstrap-key`
- `KIOSK_BASE_URL=http://10.154.37.225:5050`

Test URLs used:

- `http://10.154.37.225:5050/makerspace`
- `http://10.154.37.225:5050/maker-studio`

Note: Docker Compose was installed, but the actual server testing in this
session used direct `python run.py` startup rather than a live compose stack.

### Pilot Pi

Host used for SSH during testing:

- `Printer-Kiosk2`

Observed Pi state:

- CUPS queue exists: `QL-800`
- `print-tracker-agent` systemd service is active
- Pi agent successfully registered after the slug normalization fix
- Pi was configured for Maker Studio, not Makerspace

Pi-side configuration observed:

- `SERVER_BASE_URL=http://10.154.37.225:5050`
- `AGENT_ID=maker-studio-pi-01`
- `AGENT_SPACE_SLUG=makerstudio`
- `LABEL_PRINTER_QUEUE=QL-800`

Key debugging finding:

- Jobs queued under `makerspace` will not print on this Pi because the Pi is
  intentionally assigned to `maker-studio`.
- This was not a print transport bug. It was a correct space-routing behavior.

The user confirmed the corrected path-based routing behavior works.

## Files Changed For The Overhaul

Core files added or changed in this phase:

- `print_tracker/models.py`
- `print_tracker/config.py`
- `print_tracker/__init__.py`
- `print_tracker/routes/patron.py`
- `print_tracker/routes/api.py`
- `print_tracker/routes/spaces.py`
- `print_tracker/services/qr_links.py`
- `print_tracker/services/spaces.py`
- `print_tracker/templates/base.html`
- `print_tracker/templates/patron_register.html`
- `print_tracker/templates/patron_success.html`
- `print_tracker/templates/staff_dashboard.html`
- `scripts/pi_worker.py`
- `scripts/install_pi_agent.sh`
- `Dockerfile`
- `docker-compose.yml`
- `.env.pi-agent.example`

## Validation Completed

1. Flask app boots with the new route structure.
2. PostgreSQL-safe startup fix was added so SQLite WAL setup does not run on
   non-SQLite connections.
3. Worker registration and polling API were validated with the Flask test client.
4. Local server served `/makerspace` and `/maker-studio` successfully.
5. Pi agent service on `Printer-Kiosk2` runs successfully.
6. CUPS queue `QL-800` exists and is idle/enabled on the Pi.
7. Registration error due to space slug mismatch was fixed and pushed.

## Current Gaps

These are the main missing pieces after the first POC slice:

1. Staff dashboard does not yet show agent online/offline status per space.
2. Staff dashboard does not surface queued/dispatched/printed/manual-fallback
   state cleanly for the server/agent model.
3. There is no admin view for worker registry entries.
4. There is no visible per-space queue summary for operators.
5. Patron-facing failure handling is not finalized when label printing fails.
   The success/failure screen must keep the Print ID visible, must not auto-return
   to the submit screen in the failed-label case, and must explicitly instruct the
   user to talk to staff to get a print slip.
6. Docker Compose startup has not yet been used as the primary runtime path.
7. The server still uses the existing shared staff-password model.

## Recommended Next Step

The next engineering step should be server-side operator visibility.

Implement this in the next session:

1. Add worker status summaries to the staff dashboard.
   Show each configured space, last heartbeat, assigned printer queue,
   and whether an agent is online.
2. Add per-space queue summaries.
   Show counts for queued, dispatched, printed, and manual-fallback jobs.
3. Make queued jobs visibly attributable to their target space and worker.
4. Add a small troubleshooting surface for operators.
   At minimum: latest print error and whether the assigned worker is online.
5. Update patron failed-label UX.
   If a label does not print, the screen must keep the Print ID on screen,
   must not revert automatically to the registration form, and must tell the
   user to talk to staff to get a print slip.

This is the right next step because the proof-of-concept routing contract now
works, but the system is still opaque from the UI.

## Suggested Implementation Order

1. Extend queries in `print_tracker/routes/staff.py` to load worker nodes and
   grouped job counts by `space_slug` and `print_status`.
2. Update `print_tracker/templates/staff_dashboard.html` to add:
   - worker cards
   - per-space queue counts
   - print status badges on job cards
3. Optionally add a helper service for worker health classification, for example
   online vs stale based on `last_heartbeat_at`.
4. After the UI changes, test with:
   - one Pi online for `maker-studio`
   - a queued `makerspace` job
   - a queued `maker-studio` job
   to confirm the dashboard makes the routing distinction obvious.
5. Add a failed-label test.
   Confirm that when printing fails, the patron screen keeps the Print ID visible,
   does not auto-reset back to registration, and clearly instructs the patron to
   talk to staff for a print slip.

## Useful Commands

### Local server

```bash
export WORKER_DISPATCH_ENABLED=true
export LIBRARY_HOURS_ENFORCE=false
export PORT=5050
export AGENT_BOOTSTRAP_KEY=poc-bootstrap-key
export KIOSK_BASE_URL=http://10.154.37.225:5050
./.venv/bin/python run.py
```

### Pi checks

```bash
ssh Printer-Kiosk2 'systemctl status print-tracker-agent --no-pager --full'
ssh Printer-Kiosk2 'journalctl -u print-tracker-agent -n 120 --no-pager'
ssh Printer-Kiosk2 'lpstat -e; echo ---; lpstat -p -d'
ssh Printer-Kiosk2 'grep -E "^(AGENT_ID|AGENT_SPACE_SLUG|SERVER_BASE_URL|LABEL_PRINTER_QUEUE)=" /home/hunt-print/printtracker-overhaul/.env.pi-agent'
```

### Git workflow

```bash
git fetch upstream
git log --oneline --decorate --max-count=5 origin/main
git log --oneline --decorate --max-count=5 upstream/main
```

## Notes For The Next Session

1. Do not waste time re-debugging the Pi print failure from this session as a
   transport problem unless a same-space job still fails.
2. The key lesson from this round: the worker was healthy, but there was no UI
   visibility into the fact that it was assigned to a different space than the
   queued jobs.
3. The next step is not more API plumbing. It is making dispatch state visible
   and understandable to staff, plus making failed-label patron behavior safe
   and unambiguous.

6. **README rewrite**
   - Full deployment docs: Pi setup, Cloudflare Tunnel, Google OAuth
   - Architecture diagram and roadmap
   - Configuration reference tables
   - Troubleshooting guide

## On-Call Runbook (Quick Triage)

Use this order during incidents:

1. Confirm app process is up.
   - sudo systemctl status print-tracker --no-pager
   - journalctl -u print-tracker -n 120 --no-pager

2. Confirm tunnel/public access path.
   - sudo systemctl status cloudflared --no-pager
   - journalctl -u cloudflared -n 120 --no-pager
   - verify KIOSK_BASE_URL in .env matches the live hostname

3. Check hours enforcement behavior.
   - verify LIBRARY_HOURS_ENFORCE=true in .env
   - verify LIBRARY_HOURS_LIBRARY_SHORT_NAME and LIBRARY_HOURS_SERVICE_SHORT_NAME
   - if a user can still register while closed, confirm they are not in a staff-authenticated browser session

4. Check physical label printing path.
   - verify LABEL_PRINT_MODE is cups (not mock)
   - verify LABEL_PRINTER_QUEUE exists in CUPS
   - lpstat -e
   - lpstat -p -d
   - lp -d QL-800 /usr/share/cups/data/testprint

5. Check label assets/layout anomalies.
   - verify LABEL_BRAND_LOGO_PATH and LABEL_SIDE_ART_PATH files exist
   - missing files should not block label generation, but artwork will be omitted

6. Check integrations.
   - for Sheets: verify GOOGLE_SHEETS_SYNC_ENABLED, spreadsheet ID, worksheet, and OAuth account access
   - for email: verify EMAIL_PROVIDER path (gmail_api or smtp) and related credentials

7. Last-resort dependency recovery.
   - sudo systemctl stop print-tracker || true
   - rm -rf .venv
   - ./scripts/deploy_rpi.sh

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
