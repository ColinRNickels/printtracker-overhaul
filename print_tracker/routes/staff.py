from datetime import datetime, timezone
from urllib.parse import urlparse

from flask import (
    Blueprint,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from sqlalchemy import func
from sqlalchemy.orm import joinedload
from werkzeug.security import check_password_hash

from ..extensions import db, limiter
from ..models import (
    JOB_STATUS_CANCELLED,
    JOB_STATUS_FAILED,
    JOB_STATUS_FINISHED,
    JOB_STATUS_IN_PROGRESS,
    PRINT_STATUS_DISPATCHED,
    PRINT_STATUS_PRINTED,
    PRINT_STATUS_QUEUED,
    PrintJob,
    WorkerNode,
)
from ..routes.patron import build_label_kwargs
from ..services.label_printer import cleanup_saved_labels, create_and_print_label
from ..services.notifier import send_completion_email
from ..services.runtime_settings import (
    KEY_EMAIL_ENABLED,
    KEY_LABEL_RETENTION_DAYS,
    KEY_QR_PAYLOAD_MODE,
    KEY_SAVE_LABEL_FILES,
    get_operational_settings,
    set_bool_setting,
    set_choice_setting,
    set_int_setting,
)
from ..services.sheets_sync import sync_job_to_google_sheet
from ..services.spaces import get_spaces, normalize_space_slug
from ..services.worker_status import build_worker_health

bp = Blueprint("staff", __name__, url_prefix="/staff")
STAFF_SESSION_KEY = "staff_authenticated"


def _extract_label_code(scan_value: str) -> str:
    raw = scan_value.strip()
    if not raw:
        return ""

    if "/" in raw:
        parsed = urlparse(raw)
        if parsed.path:
            raw = parsed.path.rstrip("/").split("/")[-1]

    raw = raw.split("?", 1)[0].split("#", 1)[0]
    return raw.strip().upper()


def _is_safe_next_url(value: str) -> bool:
    if not value:
        return False
    return value.startswith("/") and not value.startswith("//")


def _sanitize_next_url(value: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""

    if raw.startswith("/"):
        return raw if _is_safe_next_url(raw) else ""

    parsed = urlparse(raw)
    if (
        parsed.scheme in {"http", "https"}
        and parsed.netloc
        and parsed.netloc == request.host
    ):
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"
        return path if path.startswith("/") else f"/{path}"

    return ""


def _safe_redirect_target(value: str, *, fallback_endpoint: str) -> str:
    destination = _sanitize_next_url(value)
    if _is_safe_next_url(destination):
        return destination
    return url_for(fallback_endpoint)


def _find_job_by_code(label_code: str) -> PrintJob | None:
    return PrintJob.query.filter_by(label_code=label_code.upper()).first()


def _build_completion_form_data(form_data: dict | None = None) -> dict:
    defaults = {
        "completion_status": JOB_STATUS_FINISHED,
        "completed_by": "",
        "completion_notes": "",
    }
    if form_data:
        defaults.update(form_data)
    return defaults


def _space_display_lookup() -> dict[str, str]:
    return {
        normalize_space_slug(space["slug"]): space["display_name"]
        for space in get_spaces()
    }


def _worker_dashboard_rows() -> list[dict[str, object]]:
    workers = (
        WorkerNode.query.filter_by(is_active=True)
        .order_by(WorkerNode.space_slug.asc(), WorkerNode.display_name.asc())
        .all()
    )
    now = datetime.now(timezone.utc)
    return [
        {
            "worker": worker,
            "health": build_worker_health(worker, now=now),
        }
        for worker in workers
    ]


def _queue_counts_by_space() -> tuple[dict[str, dict[str, int]], dict[str, int]]:
    rows = (
        db.session.query(
            PrintJob.space_slug,
            PrintJob.print_status,
            func.count(PrintJob.id),
        )
        .filter(PrintJob.status == JOB_STATUS_IN_PROGRESS)
        .group_by(PrintJob.space_slug, PrintJob.print_status)
        .all()
    )
    counts_by_space: dict[str, dict[str, int]] = {}
    total_counts = {
        PRINT_STATUS_QUEUED: 0,
        PRINT_STATUS_DISPATCHED: 0,
        PRINT_STATUS_PRINTED: 0,
        "manual_fallback": 0,
    }

    for space_slug, print_status, count in rows:
        space_key = normalize_space_slug(space_slug)
        space_counts = counts_by_space.setdefault(space_key, {})
        space_counts[print_status] = count
        if print_status in total_counts:
            total_counts[print_status] += count

    manual_rows = (
        db.session.query(PrintJob.space_slug, func.count(PrintJob.id))
        .filter(
            PrintJob.status == JOB_STATUS_IN_PROGRESS,
            PrintJob.manual_fallback_required.is_(True),
        )
        .group_by(PrintJob.space_slug)
        .all()
    )
    for space_slug, count in manual_rows:
        space_key = normalize_space_slug(space_slug)
        counts_by_space.setdefault(space_key, {})["manual_fallback"] = count
        total_counts["manual_fallback"] += count

    return counts_by_space, total_counts


def _latest_error_by_space() -> dict[str, PrintJob]:
    jobs = (
        PrintJob.query.options(joinedload(PrintJob.assigned_worker))
        .filter(
            PrintJob.status == JOB_STATUS_IN_PROGRESS,
            PrintJob.print_error.isnot(None),
        )
        .order_by(PrintJob.print_dispatched_at.desc(), PrintJob.created_at.desc())
        .all()
    )
    errors: dict[str, PrintJob] = {}
    for job in jobs:
        errors.setdefault(normalize_space_slug(job.space_slug), job)
    return errors


def _build_space_dashboard() -> tuple[list[dict[str, object]], dict[str, int]]:
    worker_rows = _worker_dashboard_rows()
    counts_by_space, total_counts = _queue_counts_by_space()
    latest_error_by_space = _latest_error_by_space()

    workers_by_space: dict[str, list[dict[str, object]]] = {}
    online_workers = 0
    for row in worker_rows:
        worker = row["worker"]
        health = row["health"]
        space_key = normalize_space_slug(worker.space_slug)
        workers_by_space.setdefault(space_key, []).append(row)
        if health["state"] == "online":
            online_workers += 1

    dashboard_spaces: list[dict[str, object]] = []
    for space in get_spaces():
        space_key = normalize_space_slug(space["slug"])
        workers = workers_by_space.get(space_key, [])
        queue_counts = counts_by_space.get(space_key, {})
        dashboard_spaces.append(
            {
                "space": space,
                "workers": workers,
                "has_online_worker": any(
                    row["health"]["state"] == "online" for row in workers
                ),
                "queue_counts": {
                    "queued": queue_counts.get(PRINT_STATUS_QUEUED, 0),
                    "dispatched": queue_counts.get(PRINT_STATUS_DISPATCHED, 0),
                    "printed": queue_counts.get(PRINT_STATUS_PRINTED, 0),
                    "manual_fallback": queue_counts.get("manual_fallback", 0),
                },
                "latest_error_job": latest_error_by_space.get(space_key),
            }
        )

    total_counts["online_workers"] = online_workers
    total_counts["configured_spaces"] = len(dashboard_spaces)
    return dashboard_spaces, total_counts


@bp.before_request
def require_staff_password():
    if request.endpoint in {"staff.login"}:
        return None
    if session.get(STAFF_SESSION_KEY):
        return None
    next_target = request.full_path.rstrip("?")
    return redirect(url_for("staff.login", next=next_target))


@bp.route("/login", methods=["GET", "POST"])
@limiter.limit("10/minute")
def login():
    next_url = _sanitize_next_url(request.args.get("next", ""))
    if request.method == "POST":
        password = request.form.get("password", "")
        if check_password_hash(current_app.config["STAFF_PASSWORD_HASH"], password):
            session.clear()
            session.permanent = True
            session[STAFF_SESSION_KEY] = True
            destination = _safe_redirect_target(
                request.form.get("next", ""),
                fallback_endpoint="staff.dashboard",
            )
            flash("Staff access granted.", "success")
            return redirect(destination)
        flash("Incorrect staff password.", "error")
        next_url = _sanitize_next_url(request.form.get("next", next_url))

    return render_template(
        "staff_login.html",
        next_url=next_url if _is_safe_next_url(next_url) else "",
    )


@bp.route("/logout", methods=["POST"])
def logout():
    session.clear()
    flash("Signed out of staff mode.", "success")
    return redirect(url_for("staff.login"))


@bp.route("/", methods=["GET"])
def dashboard():
    operational_settings = get_operational_settings()
    kiosk_base_url = (current_app.config.get("KIOSK_BASE_URL", "") or "").strip()
    qr_link_url_warning = operational_settings["qr_payload_mode"] == "url" and (
        not kiosk_base_url
        or "localhost" in kiosk_base_url.lower()
        or "127.0.0.1" in kiosk_base_url
    )

    if operational_settings["save_label_files"]:
        deleted = cleanup_saved_labels(
            current_app.config["LABEL_OUTPUT_DIR"],
            keep_days=operational_settings["label_retention_days"],
        )
        if deleted:
            current_app.logger.info("Removed %s old label image(s).", deleted)

    space_display_lookup = _space_display_lookup()
    space_dashboard, queue_totals = _build_space_dashboard()
    in_progress = (
        PrintJob.query.options(joinedload(PrintJob.assigned_worker))
        .filter_by(status=JOB_STATUS_IN_PROGRESS)
        .order_by(PrintJob.created_at.asc())
        .all()
    )
    recently_completed = (
        PrintJob.query.options(joinedload(PrintJob.assigned_worker))
        .filter(
            PrintJob.status.in_(
                [JOB_STATUS_FINISHED, JOB_STATUS_FAILED, JOB_STATUS_CANCELLED]
            )
        )
        .order_by(PrintJob.completed_at.desc())
        .limit(25)
        .all()
    )
    site_id = (current_app.config.get("SITE_ID", "") or "").strip().upper()
    label_prefix = site_id if site_id else "PT"

    return render_template(
        "staff_dashboard.html",
        in_progress=in_progress,
        recently_completed=recently_completed,
        space_dashboard=space_dashboard,
        space_display_lookup=space_display_lookup,
        queue_totals=queue_totals,
        operational_settings=operational_settings,
        email_provider=current_app.config.get("EMAIL_PROVIDER", "smtp"),
        kiosk_base_url=kiosk_base_url,
        qr_link_url_warning=qr_link_url_warning,
        label_prefix=label_prefix,
    )


@bp.route("/settings", methods=["POST"])
def update_settings():
    completion_email_enabled = bool(request.form.get("completion_email_enabled"))
    save_label_files = bool(request.form.get("save_label_files"))
    raw_retention = request.form.get("label_retention_days", "1").strip()
    qr_payload_mode = request.form.get("qr_payload_mode", "url").strip().lower()

    try:
        label_retention_days = int(raw_retention)
    except ValueError:
        flash("Label retention days must be a whole number.", "error")
        return redirect(url_for("staff.dashboard"))

    set_bool_setting(KEY_EMAIL_ENABLED, completion_email_enabled)
    set_bool_setting(KEY_SAVE_LABEL_FILES, save_label_files)
    set_int_setting(
        KEY_LABEL_RETENTION_DAYS, label_retention_days, minimum=1, maximum=30
    )
    set_choice_setting(
        KEY_QR_PAYLOAD_MODE, qr_payload_mode, choices={"id", "url"}, fallback="url"
    )
    db.session.commit()

    if save_label_files:
        cleanup_saved_labels(
            current_app.config["LABEL_OUTPUT_DIR"],
            keep_days=max(1, min(30, label_retention_days)),
        )
    flash("Operational settings updated.", "success")
    return redirect(url_for("staff.dashboard"))


@bp.route("/scan", methods=["POST"])
def scan():
    code = _extract_label_code(request.form.get("scan_value", ""))
    if not code:
        flash("No scan value detected.", "error")
        return redirect(url_for("staff.dashboard"))
    job = _find_job_by_code(code)
    if not job:
        flash(f"No print found for {code}.", "error")
        return redirect(url_for("staff.dashboard"))
    return redirect(url_for("staff.complete_job", label_code=job.label_code))


@bp.route("/s/<label_code>", methods=["GET"])
def scan_shortcut(label_code: str):
    code = _extract_label_code(label_code)
    if not code:
        flash("Invalid print ID.", "error")
        return redirect(url_for("staff.dashboard"))
    job = _find_job_by_code(code)
    if not job:
        flash(f"No print found for {code}.", "error")
        return redirect(url_for("staff.dashboard"))
    return redirect(url_for("staff.complete_job", label_code=job.label_code))


@bp.route("/reprint/<label_code>", methods=["POST"])
def reprint(label_code: str):
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    label_result = create_and_print_label(**build_label_kwargs(job))
    if label_result.get("printed"):
        flash(f"Reprint sent for {job.label_code}.", "success")
    else:
        flash(
            f"Reprint was not sent for {job.label_code}: {label_result['message']}",
            "warning",
        )
    return redirect(
        _safe_redirect_target(
            request.referrer or "",
            fallback_endpoint="staff.dashboard",
        )
    )


@bp.route("/cancel/<label_code>", methods=["POST"])
def cancel_job(label_code: str):
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    if job.is_completed:
        flash("This job is already completed.", "warning")
        return redirect(url_for("staff.dashboard"))

    completed_by = " ".join(request.form.get("completed_by", "").split())
    if not completed_by:
        flash("Staff name is required to cancel a job.", "error")
        return redirect(url_for("staff.dashboard"))

    job.mark_completed(
        outcome=JOB_STATUS_CANCELLED,
        completed_by=completed_by,
        completion_notes=None,
    )
    job.email_status = "skipped"
    job.email_error = "Email not sent for cancelled jobs."
    db.session.commit()

    sync_ok, sync_error = sync_job_to_google_sheet(job)
    if not sync_ok:
        current_app.logger.warning(
            "Google Sheets sync failed for %s at cancellation: %s",
            job.label_code,
            sync_error,
        )
        flash(f"Google Sheets sync failed: {sync_error}", "warning")

    flash(f"{job.label_code} cancelled.", "success")
    return redirect(url_for("staff.dashboard"))


@bp.route("/complete/<label_code>", methods=["GET", "POST"])
def complete_job(label_code: str):
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    form_data = _build_completion_form_data()

    if request.method == "POST":
        if job.is_completed:
            flash("This job is already completed.", "warning")
            return redirect(url_for("staff.complete_job", label_code=job.label_code))

        completion_status = request.form.get("completion_status", "").strip()
        completed_by = " ".join(request.form.get("completed_by", "").split())
        completion_notes = request.form.get("completion_notes", "").strip()
        form_data = _build_completion_form_data(
            {
                "completion_status": completion_status,
                "completed_by": completed_by,
                "completion_notes": completion_notes,
            }
        )

        errors = []
        if completion_status not in {JOB_STATUS_FINISHED, JOB_STATUS_FAILED}:
            errors.append("Choose a completion status.")
        if not completed_by:
            errors.append("Completed by is required.")
        if completion_status == JOB_STATUS_FAILED and not completion_notes:
            errors.append("Failure description is required when status is Failed.")

        if errors:
            for error in errors:
                flash(error, "error")
            return render_template("staff_complete.html", job=job, form_data=form_data)

        job.mark_completed(
            outcome=completion_status,
            completed_by=completed_by,
            completion_notes=completion_notes,
        )

        operational_settings = get_operational_settings()
        if operational_settings["completion_email_enabled"]:
            email_status, email_error = send_completion_email(job)
        else:
            email_status, email_error = (
                "skipped",
                "Email sending disabled by staff settings.",
            )

        job.email_status = email_status
        job.email_error = email_error
        if email_status == "sent":
            job.email_sent_at = datetime.now(timezone.utc)

        db.session.commit()

        sync_ok, sync_error = sync_job_to_google_sheet(job)
        if not sync_ok:
            current_app.logger.warning(
                "Google Sheets sync failed for %s at completion: %s",
                job.label_code,
                sync_error,
            )
            flash(f"Google Sheets sync failed: {sync_error}", "warning")

        flash(f"Print marked as {job.status_label}.", "success")
        if email_status == "sent":
            flash("Completion email sent.", "success")
        elif email_status == "failed":
            flash(f"Email failed to send: {email_error}", "warning")
        else:
            flash(f"Email skipped: {email_error}", "warning")

        return redirect(url_for("staff.complete_job", label_code=job.label_code))

    return render_template("staff_complete.html", job=job, form_data=form_data)
