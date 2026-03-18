from datetime import datetime, timezone

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

from ..extensions import db
from ..models import PrintJob, WorkerNode
from ..services.label_printer import cleanup_saved_labels
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
from ..services.spaces import get_spaces, normalize_space_slug
from ..services.worker_status import build_worker_health
from .staff import STAFF_SESSION_KEY, _build_space_dashboard, _sanitize_next_url

bp = Blueprint("admin", __name__, url_prefix="/admin")


def _space_display_lookup() -> dict[str, str]:
    return {
        normalize_space_slug(space["slug"]): space["display_name"]
        for space in get_spaces()
    }


def _worker_registry_rows() -> list[dict[str, object]]:
    workers = WorkerNode.query.order_by(
        WorkerNode.is_active.desc(),
        WorkerNode.space_slug.asc(),
        WorkerNode.display_name.asc(),
    ).all()
    now = datetime.now(timezone.utc)
    space_display_lookup = _space_display_lookup()
    rows = []
    for worker in workers:
        rows.append(
            {
                "worker": worker,
                "health": build_worker_health(worker, now=now),
                "space_display": space_display_lookup.get(
                    normalize_space_slug(worker.space_slug), worker.space_slug
                ),
            }
        )
    return rows


@bp.before_request
def require_staff_password():
    if session.get(STAFF_SESSION_KEY):
        return None
    next_target = _sanitize_next_url(request.full_path.rstrip("?"))
    return redirect(url_for("staff.login", next=next_target))


@bp.route("/", methods=["GET"])
def dashboard():
    operational_settings = get_operational_settings()
    kiosk_base_url = (current_app.config.get("KIOSK_BASE_URL", "") or "").strip()
    qr_link_url_warning = operational_settings["qr_payload_mode"] == "url" and (
        not kiosk_base_url
        or "localhost" in kiosk_base_url.lower()
        or "127.0.0.1" in kiosk_base_url
    )
    space_dashboard, queue_totals = _build_space_dashboard()
    worker_registry = _worker_registry_rows()

    return render_template(
        "admin_dashboard.html",
        operational_settings=operational_settings,
        email_provider=current_app.config.get("EMAIL_PROVIDER", "smtp"),
        kiosk_base_url=kiosk_base_url,
        qr_link_url_warning=qr_link_url_warning,
        queue_totals=queue_totals,
        space_dashboard=space_dashboard,
        worker_registry=worker_registry,
    )


@bp.route("/settings", methods=["POST"])
def update_settings():
    completion_email_enabled = bool(request.form.get("completion_email_enabled"))
    save_label_files = bool(request.form.get("save_label_files"))
    raw_retention = request.form.get("label_retention_days", "1").strip()

    try:
        label_retention_days = int(raw_retention)
    except ValueError:
        flash("Label retention days must be a whole number.", "error")
        return redirect(url_for("admin.dashboard"))

    set_bool_setting(KEY_EMAIL_ENABLED, completion_email_enabled)
    set_bool_setting(KEY_SAVE_LABEL_FILES, save_label_files)
    set_int_setting(
        KEY_LABEL_RETENTION_DAYS, label_retention_days, minimum=1, maximum=30
    )
    set_choice_setting(
        KEY_QR_PAYLOAD_MODE, "url", choices={"id", "url"}, fallback="url"
    )
    db.session.commit()

    if save_label_files:
        cleanup_saved_labels(
            current_app.config["LABEL_OUTPUT_DIR"],
            keep_days=max(1, min(30, label_retention_days)),
        )

    flash("Operational settings updated.", "success")
    return redirect(url_for("admin.dashboard"))


@bp.route("/workers/<int:worker_id>/state", methods=["POST"])
def update_worker_state(worker_id: int):
    worker = WorkerNode.query.get_or_404(worker_id)
    action = (request.form.get("action") or "").strip().lower()

    if action == "deactivate":
        worker.is_active = False
        worker.status = "inactive"
        flash(f"{worker.display_name} deactivated.", "success")
    elif action == "activate":
        worker.is_active = True
        worker.status = "pending"
        flash(f"{worker.display_name} reactivated.", "success")
    else:
        flash("Invalid worker action.", "error")
        return redirect(url_for("admin.dashboard"))

    db.session.commit()
    return redirect(url_for("admin.dashboard"))


@bp.route("/workers/<int:worker_id>/delete", methods=["POST"])
def delete_worker(worker_id: int):
    worker = WorkerNode.query.get_or_404(worker_id)

    # Keep historical jobs intact while removing stale/test registry entries.
    PrintJob.query.filter_by(assigned_worker_id=worker.id).update(
        {"assigned_worker_id": None}, synchronize_session=False
    )
    worker_name = worker.display_name
    db.session.delete(worker)
    db.session.commit()

    flash(f"{worker_name} removed from worker registry.", "success")
    return redirect(url_for("admin.dashboard"))
