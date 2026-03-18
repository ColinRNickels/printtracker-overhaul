from __future__ import annotations

from datetime import datetime, timezone

from flask import Blueprint, current_app, jsonify, request
from sqlalchemy import or_

from ..extensions import csrf, db
from ..models import (
    PRINT_STATUS_DISPATCHED,
    PRINT_STATUS_QUEUED,
    PrintJob,
    WorkerNode,
)
from ..services.qr_links import build_staff_completion_url
from ..services.spaces import get_space, normalize_space_slug


bp = Blueprint("api", __name__, url_prefix="/api")
csrf.exempt(bp)


def _json_error(message: str, status: int):
    response = jsonify({"error": message})
    response.status_code = status
    return response


def _request_json() -> dict:
    return request.get_json(silent=True) or {}


def _normalize_agent_id(value: str | None) -> str:
    return "".join((value or "").strip().split())


def _extract_bearer_token() -> str:
    auth_header = (request.headers.get("Authorization") or "").strip()
    if not auth_header.lower().startswith("bearer "):
        return ""
    return auth_header[7:].strip()


def _authenticate_agent() -> WorkerNode | None:
    agent_id = _normalize_agent_id(request.headers.get("X-Agent-ID"))
    raw_token = _extract_bearer_token()
    if not agent_id or not raw_token:
        return None
    worker = WorkerNode.query.filter_by(agent_id=agent_id, is_active=True).first()
    if not worker or not worker.check_token(raw_token):
        return None
    worker.last_seen_ip = request.remote_addr
    worker.last_heartbeat_at = datetime.now(timezone.utc)
    worker.status = "online"
    db.session.commit()
    return worker


def _job_payload(job: PrintJob) -> dict:
    return {
        "label_code": job.label_code,
        "space_slug": job.space_slug,
        "location": job.location,
        "printer_name": job.printer_name,
        "print_title": job.print_title,
        "user_name": job.user_name,
        "user_email": job.user_email,
        "category": job.category,
        "course_number": job.course_number,
        "instructor": job.instructor,
        "department": job.department,
        "pi_name": job.pi_name,
        "notes": job.notes,
        "created_at": job.created_at.isoformat() if job.created_at else None,
        "completion_url": build_staff_completion_url(
            job.label_code,
            space_slug=job.space_slug,
        ),
    }


@bp.post("/agents/register")
def register_agent():
    bootstrap_key = current_app.config.get("AGENT_BOOTSTRAP_KEY", "")
    if not bootstrap_key:
        return _json_error("Agent bootstrap is not enabled on this server.", 503)

    payload = _request_json()
    if payload.get("bootstrap_key", "").strip() != bootstrap_key:
        return _json_error("Invalid bootstrap key.", 403)

    agent_id = _normalize_agent_id(payload.get("agent_id"))
    if not agent_id:
        return _json_error("agent_id is required.", 400)

    space = get_space(payload.get("space_slug"))
    if not space:
        return _json_error("A valid space_slug is required.", 400)

    worker = WorkerNode.query.filter_by(agent_id=agent_id).first()
    if worker is None:
        worker = WorkerNode(agent_id=agent_id)
        db.session.add(worker)

    worker.display_name = (payload.get("display_name") or agent_id).strip() or agent_id
    worker.space_slug = space["slug"]
    worker.printer_queue = (payload.get("printer_queue") or "").strip() or None
    worker.software_version = (payload.get("software_version") or "").strip() or None
    worker.last_seen_ip = request.remote_addr
    worker.last_heartbeat_at = datetime.now(timezone.utc)
    worker.status = "online"
    worker.is_active = True
    raw_token = worker.issue_token()
    db.session.commit()

    return jsonify(
        {
            "agent": {
                "agent_id": worker.agent_id,
                "space_slug": worker.space_slug,
                "display_name": worker.display_name,
                "printer_queue": worker.printer_queue,
            },
            "token": raw_token,
        }
    )


@bp.post("/agents/heartbeat")
def heartbeat():
    worker = _authenticate_agent()
    if not worker:
        return _json_error("Authentication required.", 401)
    return jsonify(
        {
            "ok": True,
            "agent_id": worker.agent_id,
            "space_slug": worker.space_slug,
            "last_heartbeat_at": worker.last_heartbeat_at.isoformat()
            if worker.last_heartbeat_at
            else None,
        }
    )


@bp.get("/agents/jobs")
def poll_jobs():
    worker = _authenticate_agent()
    if not worker:
        return _json_error("Authentication required.", 401)

    limit = request.args.get("limit", type=int) or current_app.config.get(
        "AGENT_POLL_BATCH_SIZE", 5
    )
    limit = max(1, min(limit, 25))

    jobs = (
        PrintJob.query.filter(
            PrintJob.space_slug == normalize_space_slug(worker.space_slug),
            PrintJob.print_status.in_([PRINT_STATUS_QUEUED, PRINT_STATUS_DISPATCHED]),
            or_(
                PrintJob.assigned_worker_id.is_(None),
                PrintJob.assigned_worker_id == worker.id,
            ),
        )
        .order_by(PrintJob.created_at.asc())
        .limit(limit)
        .all()
    )

    for job in jobs:
        if job.assigned_worker_id is None:
            job.mark_print_dispatched(worker_id=worker.id)
    db.session.commit()

    return jsonify({"jobs": [_job_payload(job) for job in jobs]})


@bp.post("/agents/jobs/<label_code>/printed")
def mark_job_printed(label_code: str):
    worker = _authenticate_agent()
    if not worker:
        return _json_error("Authentication required.", 401)

    job = PrintJob.query.filter_by(label_code=label_code.upper()).first()
    if not job or normalize_space_slug(job.space_slug) != normalize_space_slug(worker.space_slug):
        return _json_error("Job not found for this worker.", 404)

    job.mark_printed(worker_id=worker.id)
    db.session.commit()
    return jsonify({"ok": True, "label_code": job.label_code, "print_status": job.print_status})


@bp.post("/agents/jobs/<label_code>/failed")
def mark_job_print_failed(label_code: str):
    worker = _authenticate_agent()
    if not worker:
        return _json_error("Authentication required.", 401)

    payload = _request_json()
    job = PrintJob.query.filter_by(label_code=label_code.upper()).first()
    if not job or normalize_space_slug(job.space_slug) != normalize_space_slug(worker.space_slug):
        return _json_error("Job not found for this worker.", 404)

    error_message = (payload.get("error") or "Print agent reported a failure.").strip()
    job.mark_print_failed(error_message=error_message, worker_id=worker.id)
    db.session.commit()
    return jsonify(
        {
            "ok": True,
            "label_code": job.label_code,
            "print_status": job.print_status,
            "manual_fallback_required": job.manual_fallback_required,
        }
    )