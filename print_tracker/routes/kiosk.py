import io
import time
from datetime import datetime
from pathlib import Path

from flask import (
    Blueprint,
    abort,
    current_app,
    flash,
    render_template,
    request,
    send_file,
    url_for,
)

from ..extensions import db
from ..models import (
    JOB_CATEGORIES,
    JOB_CATEGORY_COURSE,
    JOB_CATEGORY_PERSONAL,
    JOB_CATEGORY_RESEARCH,
    PrintJob,
)
from ..services.label_printer import build_qr_image, create_and_print_label
from ..services.qr_links import build_staff_completion_url
from ..services.runtime_settings import get_operational_settings
from ..services.sheets_sync import sync_job_to_google_sheet

bp = Blueprint("kiosk", __name__, url_prefix="/kiosk")
NCSU_EMAIL_DOMAIN = "ncsu.edu"
CATEGORY_OPTIONS = [
    (JOB_CATEGORY_PERSONAL, "Personal"),
    (JOB_CATEGORY_COURSE, "Academic"),
    (JOB_CATEGORY_RESEARCH, "Research"),
]


def build_label_kwargs(job) -> dict:
    """Build the keyword arguments for create_and_print_label.

    Shared between kiosk registration and staff reprint to avoid
    duplicating ~15 config/settings lookups.
    """
    operational_settings = get_operational_settings()
    completion_url = build_staff_completion_url(job.label_code)
    return dict(
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


def _generate_label_code() -> str:
    # Format: <PREFIX>-YYYYMMDD-HHMMSS-##
    # PREFIX defaults to "PT" but can be overridden via SITE_ID to avoid
    # collisions when multiple Pis sync to the same Google Sheet.
    site_id = current_app.config.get("SITE_ID", "").strip().upper()
    prefix = site_id if site_id else "PT"
    for _ in range(3):
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        for sequence in range(100):
            code = f"{prefix}-{timestamp}-{sequence:02d}"
            if not PrintJob.query.filter_by(label_code=code).first():
                return code
        time.sleep(1)
    raise RuntimeError("Could not generate unique label code")


def _normalize_ncsu_email(raw_value: str) -> str:
    value = raw_value.strip().lower()
    if not value:
        raise ValueError("Email is required.")

    if "@" in value:
        local_part, domain = value.split("@", 1)
    else:
        local_part, domain = value, NCSU_EMAIL_DOMAIN

    local_part = local_part.strip()
    domain = domain.strip()
    if not local_part:
        raise ValueError("Email is required.")
    if domain and domain != NCSU_EMAIL_DOMAIN:
        raise ValueError(f"Email must use @{NCSU_EMAIL_DOMAIN}.")
    return f"{local_part}@{NCSU_EMAIL_DOMAIN}"


def _normalize_person_name(raw_value: str) -> str:
    return " ".join(raw_value.strip().split())


@bp.route("/register", methods=["GET", "POST"])
def register():
    form = {
        "file_name": "",
        "first_name": "",
        "last_name": "",
        "user_email_local": "",
        "category": JOB_CATEGORY_PERSONAL,
        "course_number": "",
        "instructor": "",
        "department": "",
        "pi_name": "",
    }

    if request.method == "POST":
        form.update({key: request.form.get(key, "").strip() for key in form})
        form["first_name"] = _normalize_person_name(form["first_name"])
        form["last_name"] = _normalize_person_name(form["last_name"])
        errors = []

        if not form["file_name"]:
            errors.append("File name is required.")
        if not form["first_name"]:
            errors.append("First name is required.")
        if not form["last_name"]:
            errors.append("Last name is required.")
        if form["category"] not in JOB_CATEGORIES:
            errors.append("Choose a valid category.")
        if form["category"] == JOB_CATEGORY_COURSE:
            if not form["course_number"]:
                errors.append("Course # is required for Academic prints.")
            if not form["instructor"]:
                errors.append("Instructor is required for Academic prints.")
        if form["category"] == JOB_CATEGORY_RESEARCH:
            if not form["department"]:
                errors.append("Department is required for Research prints.")
            if not form["pi_name"]:
                errors.append("PI is required for Research prints.")

        user_email = ""
        try:
            user_email = _normalize_ncsu_email(form["user_email_local"])
        except ValueError as exc:
            errors.append(str(exc))

        if errors:
            for error in errors:
                flash(error, "error")
            return render_template(
                "kiosk_register.html",
                form=form,
                category_options=CATEGORY_OPTIONS,
                ncsu_domain=NCSU_EMAIL_DOMAIN,
            )

        full_name = f"{form['first_name']} {form['last_name']}".strip()

        job = PrintJob(
            label_code=_generate_label_code(),
            print_title=form["file_name"],
            user_name=full_name,
            user_email=user_email,
            printer_name=current_app.config["DEFAULT_PRINTER_NAME"],
            category=form["category"],
            course_number=form["course_number"] or None,
            instructor=form["instructor"] or None,
            department=form["department"] or None,
            pi_name=form["pi_name"] or None,
            location=current_app.config["DEFAULT_PRINTER_NAME"],
            notes=None,
        )
        db.session.add(job)
        db.session.commit()

        sync_ok, sync_error = sync_job_to_google_sheet(job)
        if not sync_ok:
            current_app.logger.warning(
                "Google Sheets sync failed for %s at registration: %s",
                job.label_code,
                sync_error,
            )

        label_result = create_and_print_label(**build_label_kwargs(job))

        return render_template(
            "kiosk_success.html",
            job=job,
            label_result=label_result,
            sync_error=sync_error if not sync_ok else None,
        )

    return render_template(
        "kiosk_register.html",
        form=form,
        category_options=CATEGORY_OPTIONS,
        ncsu_domain=NCSU_EMAIL_DOMAIN,
    )


@bp.route("/qr/<label_code>.png")
def qr_code_image(label_code: str):
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    operational_settings = get_operational_settings()
    completion_url = build_staff_completion_url(job.label_code)
    payload = (
        completion_url
        if operational_settings["qr_payload_mode"] == "url"
        else job.label_code
    )
    image = build_qr_image(payload, size=320)
    image_bytes = io.BytesIO()
    image.save(image_bytes, format="PNG")
    image_bytes.seek(0)
    return send_file(image_bytes, mimetype="image/png")


@bp.route("/label-preview/<label_code>.png")
def label_preview(label_code: str):
    PrintJob.query.filter_by(label_code=label_code.upper()).first_or_404()
    label_path = (
        Path(current_app.config["LABEL_OUTPUT_DIR"]) / f"{label_code.upper()}.png"
    ).resolve()
    if not label_path.exists():
        abort(404)
    return send_file(label_path, mimetype="image/png")
