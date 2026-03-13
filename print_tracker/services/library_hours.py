"""Library hours check using the NC State Libraries hours API.

Fetches today's open/close times for a specific library space and determines
whether patrons may currently submit print jobs.  Results are cached for
CACHE_TTL seconds to avoid hammering the upstream API on every page load.
"""

import json
import logging
import time
import urllib.request
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

HOURS_API_URL = "https://www.lib.ncsu.edu/api/hours/everything.json"
CACHE_TTL = 300  # seconds between API refreshes

_cache: dict = {"data": None, "fetched_at": 0.0}


def _fetch_hours() -> list:
    """Return cached (or freshly fetched) hours list from the API.

    Falls back to the stale cache on error; returns [] if no data at all.
    """
    now = time.monotonic()
    if _cache["data"] is not None and now - _cache["fetched_at"] < CACHE_TTL:
        return _cache["data"]
    try:
        with urllib.request.urlopen(HOURS_API_URL, timeout=5) as response:
            data = json.loads(response.read().decode("utf-8"))
        _cache["data"] = data
        _cache["fetched_at"] = now
        logger.debug("Library hours refreshed from API (%d entries)", len(data))
        return data
    except Exception as exc:
        logger.warning("Failed to fetch library hours from %s: %s", HOURS_API_URL, exc)
        # Return stale cache if available so a transient outage doesn't block patrons
        return _cache["data"] or []


def check_is_open(
    library_short_name: str,
    service_short_name: str,
    post_close_buffer_minutes: int = 10,
) -> tuple[bool, str]:
    """Return ``(is_open, message)`` for the given library space right now.

    *is_open* is ``True`` when patrons may submit print jobs:
    - During normal open hours, **or**
    - Within *post_close_buffer_minutes* after closing time (so a patron who
      just finished slicing a file can still start a print without staff help).

    The function **fails open**: if hours cannot be fetched or no matching
    entry is found, ``(True, "")`` is returned so the app stays usable during
    API outages.

    Args:
        library_short_name:  API ``library_short_name`` field, e.g. ``"hill"``.
        service_short_name:  API ``service_short_name`` field, e.g. ``"makerspace"``.
        post_close_buffer_minutes:  Minutes after close time to keep accepting jobs.

    Returns:
        A ``(bool, str)`` tuple.  When closed the message is human-readable and
        suitable for display on the patron registration page.
    """
    entries = _fetch_hours()
    if not entries:
        return True, ""

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    target = None
    for entry in entries:
        if (
            entry.get("library_short_name") == library_short_name
            and entry.get("service_short_name") == service_short_name
            and entry.get("date") == today
        ):
            target = entry
            break

    if target is None:
        logger.warning(
            "No hours entry found for library=%r service=%r on %s; failing open",
            library_short_name,
            service_short_name,
            today,
        )
        return True, ""

    if target.get("closed") == "1":
        display = target.get("display", "")
        return False, f"The Makerspace is closed today. {display}".strip()

    day_start = target.get("day_start")
    day_end = target.get("day_end")

    if day_start is None or day_end is None:
        return True, ""

    now_ts = datetime.now(timezone.utc).timestamp()
    buffer_seconds = post_close_buffer_minutes * 60

    if now_ts < day_start:
        display = target.get("display", "")
        return False, f"The Makerspace is not open yet. Hours today: {display}.".strip()

    if now_ts > day_end + buffer_seconds:
        display = target.get("display", "")
        return False, f"The Makerspace is now closed. Hours today: {display}.".strip()

    return True, ""
