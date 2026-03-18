from __future__ import annotations

from flask import current_app, has_app_context


DEFAULT_SPACES = [
    {
        "slug": "makerspace",
        "display_name": "Makerspace",
        "label_prefix": "MK",
        "printer_name": "Makerspace",
    },
    {
        "slug": "maker-studio",
        "display_name": "Maker Studio",
        "label_prefix": "MS",
        "printer_name": "Maker Studio",
    },
]


def normalize_space_slug(value: str | None) -> str:
    return (
        (value or "")
        .strip()
        .lower()
        .replace("_", "-")
        .replace(" ", "-")
        .replace("/", "-")
    )


def _normalize_space_key(value: str | None) -> str:
    normalized = normalize_space_slug(value)
    return normalized.replace("-", "").replace(" ", "")


def _space_records_from_string(raw_value: str | None) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for raw_item in (raw_value or "").split(","):
        item = raw_item.strip()
        if not item:
            continue
        parts = [part.strip() for part in item.split("|")]
        slug = normalize_space_slug(parts[0] if len(parts) > 0 else "")
        display_name = parts[1] if len(parts) > 1 and parts[1] else slug.replace("-", " ").title()
        label_prefix = (parts[2] if len(parts) > 2 and parts[2] else display_name[:2]).strip().upper()
        printer_name = parts[3] if len(parts) > 3 and parts[3] else display_name
        if not slug:
            continue
        records.append(
            {
                "slug": slug,
                "display_name": display_name,
                "label_prefix": label_prefix[:4] or "PT",
                "printer_name": printer_name,
            }
        )
    return records


def get_spaces() -> list[dict[str, str]]:
    raw_value = None
    if has_app_context():
        raw_value = current_app.config.get("PRINT_TRACKER_SPACES", "")
    return _space_records_from_string(raw_value) or list(DEFAULT_SPACES)


def get_default_space() -> dict[str, str]:
    return dict(get_spaces()[0])


def get_space(space_slug: str | None) -> dict[str, str] | None:
    normalized = normalize_space_slug(space_slug)
    normalized_key = _normalize_space_key(space_slug)
    if not normalized:
        return get_default_space()
    for space in get_spaces():
        if space["slug"] == normalized:
            return dict(space)
        if _normalize_space_key(space.get("display_name")) == normalized_key:
            return dict(space)
        if _normalize_space_key(space.get("printer_name")) == normalized_key:
            return dict(space)
    return None


def get_space_label_prefix(space_slug: str | None) -> str:
    space = get_space(space_slug)
    if not space:
        return "PT"
    return space["label_prefix"]