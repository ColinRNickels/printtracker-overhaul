from datetime import datetime
from urllib.parse import urlparse

from flask import Blueprint, current_app, flash, redirect, render_template, request, session, url_for

from ..extensions import db
from ..models import (
    JOB_STATUS_FAILED,
    JOB_STATUS_FINISHED,
    JOB_STATUS_IN_PROGRESS,
    PrintJob,
)
from ..services.label_printer import cleanup_saved_labels, create_and_print_label
from ..services.notifier import send_completion_email
from ..services.qr_links import build_staff_completion_url
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
    return value.startswith("/")


def _sanitize_next_url(value: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""

    if raw.startswith("/"):
        return raw

    parsed = urlparse(raw)
    if parsed.scheme in {"http", "https"} and parsed.netloc and parsed.netloc == request.host:
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"
        return path if path.startswith("/") else f"/{path}"

    return ""


@bp.before_request
def require_staff_password():
    if request.endpoint in {"staff.login"}:
        return None
    if session.get(STAFF_SESSION_KEY):
        return None
    next_target = request.full_path.rstrip("?")
    return redirect(url_for("staff.login", next=next_target))


@bp.route("/login", methods=["GET", "POST"])
def login():
    next_url = _sanitize_next_url(request.args.get("next", ""))
    if request.method == "POST":
        password = request.form.get("password", "")
        if password == current_app.config["STAFF_PASSWORD"]:
            session[STAFF_SESSION_KEY] = True
            destination = _sanitize_next_url(request.form.get("next", ""))
            if not _is_safe_next_url(destination):
                destination = url_for("staff.dashboard")
            flash("Staff access granted.", "success")
            return redirect(destination)
        flash("Incorrect staff password.", "error")
        next_url = _sanitize_next_url(request.form.get("next", next_url))

    auto_return_to_kiosk = not (
        next_url.startswith("/staff/s/") or next_url.startswith("/staff/complete/")
    )
    return render_template(
        "staff_login.html",
        next_url=next_url if _is_safe_next_url(next_url) else "",
        auto_return_to_kiosk=auto_return_to_kiosk,
    )


@bp.route("/logout", methods=["POST"])
def logout():
    session.pop(STAFF_SESSION_KEY, None)
    flash("Signed out of staff mode.", "success")
    return redirect(url_for("staff.login"))


@bp.route("/", methods=["GET"])
def dashboard():
    operational_settings = get_operational_settings()
    kiosk_base_url = (current_app.config.get("KIOSK_BASE_URL", "") or "").strip()
    qr_link_url_warning = (
        operational_settings["qr_payload_mode"] == "url"
        and (
            not kiosk_base_url
            or "localhost" in kiosk_base_url.lower()
            or "127.0.0.1" in kiosk_base_url
        )
    )

    if operational_settings["save_label_files"]:
        deleted = cleanup_saved_labels(
            current_app.config["LABEL_OUTPUT_DIR"],
            keep_days=operational_settings["label_retention_days"],
        )
        if deleted:
            current_app.logger.info("Removed %s old label image(s).", deleted)

    in_progress = (
        PrintJob.query.filter_by(status=JOB_STATUS_IN_PROGRESS)
        .order_by(PrintJob.created_at.asc())
        .all()
    )
    recently_completed = (
        PrintJob.query.filter(PrintJob.status.in_([JOB_STATUS_FINISHED, JOB_STATUS_FAILED]))
        .order_by(PrintJob.completed_at.desc())
        .limit(25)
        .all()
    )
    return render_template(
        "staff_dashboard.html",
        in_progress=in_progress,
        recently_completed=recently_completed,
        operational_settings=operational_settings,
        email_provider=current_app.config.get("EMAIL_PROVIDER", "smtp"),
        kiosk_base_url=kiosk_base_url,
        qr_link_url_warning=qr_link_url_warning,
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
    set_int_setting(KEY_LABEL_RETENTION_DAYS, label_retention_days, minimum=1, maximum=30)
    set_choice_setting(KEY_QR_PAYLOAD_MODE, qr_payload_mode, choices={"id", "url"}, fallback="url")
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
    return redirect(url_for("staff.complete_job", label_code=code))


@bp.route("/s/<label_code>", methods=["GET"])
def scan_shortcut(label_code: str):
    code = _extract_label_code(label_code)
    if not code:
        flash("Invalid print ID.", "error")
        return redirect(url_for("staff.dashboard"))
    return redirect(url_for("staff.complete_job", label_code=code))


@bp.route("/reprint/<label_code>", methods=["POST"])
def reprint(label_code: str):
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    operational_settings = get_operational_settings()
    completion_url = build_staff_completion_url(job.label_code)
    label_result = create_and_print_label(
        job=job,
        completion_url=completion_url,
        output_dir=current_app.config["LABEL_OUTPUT_DIR"],
        mode=current_app.config["LABEL_PRINT_MODE"],
        queue_name=current_app.config["LABEL_PRINTER_QUEUE"],
        stock=current_app.config["LABEL_STOCK"],
        dpi=current_app.config["LABEL_DPI"],
        qr_payload_mode=operational_settings["qr_payload_mode"],
        qr_size_inch=current_app.config["LABEL_QR_SIZE_INCH"],
        label_orientation=current_app.config["LABEL_ORIENTATION"],
        brand_text=current_app.config["LABEL_BRAND_TEXT"],
        brand_logo_path=current_app.config["LABEL_BRAND_LOGO_PATH"],
        cups_media=current_app.config["LABEL_CUPS_MEDIA"],
        cups_extra_options=current_app.config["LABEL_CUPS_EXTRA_OPTIONS"],
        save_label_files=operational_settings["save_label_files"],
        cleanup_keep_days=operational_settings["label_retention_days"],
    )
    if label_result.get("printed"):
        flash(f"Reprint sent for {job.label_code}.", "success")
    else:
        flash(f"Reprint was not sent for {job.label_code}: {label_result['message']}", "warning")
    return redirect(request.referrer or url_for("staff.dashboard"))


@bp.route("/complete/<label_code>", methods=["GET", "POST"])
def complete_job(label_code: str):
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()

    if request.method == "POST":
        if job.is_completed:
            flash("This job is already completed.", "warning")
            return redirect(url_for("staff.complete_job", label_code=job.label_code))

        completion_status = request.form.get("completion_status", "").strip()
        completed_by = request.form.get("completed_by", "").strip()
        completion_notes = request.form.get("completion_notes", "").strip()

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
            return render_template("staff_complete.html", job=job)

        job.mark_completed(
            outcome=completion_status,
            completed_by=completed_by,
            completion_notes=completion_notes,
        )

        operational_settings = get_operational_settings()
        if operational_settings["completion_email_enabled"]:
            email_status, email_error = send_completion_email(job)
        else:
            email_status, email_error = "skipped", "Email sending disabled by staff settings."

        job.email_status = email_status
        job.email_error = email_error
        if email_status == "sent":
            job.email_sent_at = datetime.utcnow()

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

    return render_template("staff_complete.html", job=job)
