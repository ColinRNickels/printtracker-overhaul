from __future__ import annotations

from datetime import datetime, timezone

from flask import current_app, has_app_context


def _heartbeat_stale_after_seconds() -> int:
    if has_app_context():
        return int(current_app.config.get("WORKER_HEARTBEAT_STALE_SECONDS", 90))
    return 90


def _format_elapsed(seconds: int | None) -> str:
    if seconds is None:
        return "No heartbeat yet"
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60}m ago"

    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    if minutes:
        return f"{hours}h {minutes}m ago"
    return f"{hours}h ago"


def build_worker_health(worker, *, now: datetime | None = None) -> dict[str, object]:
    now = now or datetime.now(timezone.utc)
    stale_after_seconds = _heartbeat_stale_after_seconds()
    last_heartbeat_at = getattr(worker, "last_heartbeat_at", None)
    seconds_since_heartbeat = None

    if last_heartbeat_at is not None:
        if last_heartbeat_at.tzinfo is None:
            last_heartbeat_at = last_heartbeat_at.replace(tzinfo=timezone.utc)
        seconds_since_heartbeat = max(0, int((now - last_heartbeat_at).total_seconds()))

    if not getattr(worker, "is_active", True):
        state = "offline"
        label = "Inactive"
    elif seconds_since_heartbeat is None:
        state = "offline"
        label = "Offline"
    elif seconds_since_heartbeat <= stale_after_seconds:
        state = "online"
        label = "Online"
    else:
        state = "stale"
        label = "Stale"

    return {
        "state": state,
        "label": label,
        "last_heartbeat_at": last_heartbeat_at,
        "seconds_since_heartbeat": seconds_since_heartbeat,
        "last_seen_text": _format_elapsed(seconds_since_heartbeat),
        "stale_after_seconds": stale_after_seconds,
    }
