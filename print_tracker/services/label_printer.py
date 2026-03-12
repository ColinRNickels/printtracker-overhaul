import logging
import subprocess
import tempfile
from datetime import date, datetime, timedelta
from pathlib import Path
from textwrap import shorten

log = logging.getLogger(__name__)

import qrcode
from PIL import Image, ImageDraw, ImageFont


def _inch_to_px(inches: float, dpi: int) -> int:
    return int(round(inches * dpi))


def _mm_to_px(mm: float, dpi: int) -> int:
    return int(round(mm / 25.4 * dpi))


def _normalize_orientation(value: str) -> str:
    normalized = (value or "").strip().lower()
    return "portrait" if normalized == "portrait" else "landscape"


def _load_font(size: int) -> ImageFont.ImageFont:
    for candidate in ("DejaVuSans-Bold.ttf", "DejaVuSans.ttf", "Arial.ttf"):
        try:
            return ImageFont.truetype(candidate, size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def _text_height(
    draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont
) -> int:
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    return bottom - top


def _text_width(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    return right - left


def _wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    *,
    font: ImageFont.ImageFont,
    max_width: int,
) -> list[str]:
    words = text.split()
    if not words:
        return [text]

    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        candidate = f"{current} {word}"
        if _text_width(draw, candidate, font) <= max_width:
            current = candidate
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def _load_brand_logo(path: str) -> Image.Image | None:
    if not path:
        return None
    logo_path = Path(path).expanduser()
    if not logo_path.exists():
        return None
    try:
        with Image.open(logo_path) as raw_logo:
            rgba = raw_logo.convert("RGBA")
            alpha = rgba.getchannel("A")
            alpha_bbox = alpha.getbbox()
            if alpha_bbox:
                rgba = rgba.crop(alpha_bbox)

            # Preserve transparent backgrounds as white for thermal output.
            white_bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
            composited = Image.alpha_composite(white_bg, rgba).convert("L")
            # Keep anti-aliased edges while forcing strong contrast for thermal labels.
            return composited.point(lambda p: 0 if p < 210 else 255, mode="1")
    except OSError:
        return None


def _format_sort_name(raw_name: str) -> str:
    cleaned = " ".join((raw_name or "").split())
    if not cleaned:
        return "UNKNOWN"

    if "," in cleaned:
        left, right = [part.strip() for part in cleaned.split(",", 1)]
        if left and right:
            return f"{left}, {right}"
        return cleaned

    parts = cleaned.split(" ")
    if len(parts) == 1:
        return parts[0]
    first_names = " ".join(parts[:-1])
    last_name = parts[-1]
    return f"{last_name}, {first_names}"


def _label_profile(stock: str, dpi: int, *, orientation: str) -> dict:
    orientation = _normalize_orientation(orientation)
    if stock.upper() in {"DK1202", "BROTHER_DK1202", "DK-1202"}:
        # DK-1202 nominal size: 62mm x 100mm. QL-800 printable width is about 58mm.
        width_mm = 58.0
        height_mm = 100.0
        if orientation == "landscape":
            width_mm, height_mm = height_mm, width_mm
        return {
            "name": "DK-1202",
            "width_px": _mm_to_px(width_mm, dpi),
            "height_px": _mm_to_px(height_mm, dpi),
            "margin_px": _mm_to_px(2.0, dpi),
        }

    width_px = 696
    height_px = 300
    if orientation == "portrait":
        width_px, height_px = height_px, width_px
    return {
        "name": stock,
        "width_px": width_px,
        "height_px": height_px,
        "margin_px": 14,
    }


def build_qr_image(payload: str, size: int) -> Image.Image:
    qr = qrcode.QRCode(version=None, box_size=8, border=2)
    qr.add_data(payload)
    qr.make(fit=True)
    image = qr.make_image(fill_color="black", back_color="white").convert("1")
    return image.resize((size, size), Image.Resampling.NEAREST)


def _render_label_image(
    job,
    qr_payload: str,
    *,
    stock: str,
    dpi: int,
    qr_size_inch: float,
    orientation: str,
    brand_text: str,
    brand_logo_path: str,
) -> Image.Image:
    profile = _label_profile(stock, dpi, orientation=orientation)
    width = profile["width_px"]
    height = profile["height_px"]
    margin = profile["margin_px"]

    image = Image.new("1", (width, height), 1)
    draw = ImageDraw.Draw(image)

    font_base = min(width, height)
    brand_font = _load_font(max(24, font_base // 18))
    title_font = _load_font(max(52, font_base // 10))
    name_font = _load_font(max(60, font_base // 8))
    body_font = _load_font(max(36, font_base // 13))
    id_font = _load_font(max(20, font_base // 26))

    qr_size = max(_inch_to_px(0.5, dpi), _inch_to_px(qr_size_inch, dpi))
    qr_size = min(qr_size, width - (margin * 2))
    qr_x = width - margin - qr_size
    qr_y = height - margin - qr_size

    text_max_width = width - (margin * 2)
    text_width_left_of_qr = qr_x - (margin * 2)
    id_line = f"ID: {job.label_code}"
    id_line_h = _text_height(draw, id_line, id_font)
    id_y = height - margin - id_line_h
    text_max_y = min(qr_y - margin, id_y - max(8, margin // 4))
    y = margin

    logo_drawn = False
    brand_logo = _load_brand_logo(brand_logo_path)
    if brand_logo:
        max_logo_w = text_max_width
        max_logo_h = max(48, min(height // 4, _mm_to_px(22, dpi)))
        scaled_logo = brand_logo.copy()
        scaled_logo.thumbnail((max_logo_w, max_logo_h), Image.Resampling.NEAREST)
        logo_x = margin + (max_logo_w - scaled_logo.width) // 2
        image.paste(scaled_logo, (logo_x, y))
        y += scaled_logo.height + max(6, margin // 4)
        logo_drawn = True

    cleaned_brand_text = " ".join((brand_text or "").split())
    if cleaned_brand_text and not logo_drawn:
        for line in _wrap_text(
            draw, cleaned_brand_text, font=brand_font, max_width=text_max_width
        ):
            line_h = _text_height(draw, line, brand_font)
            if y + line_h > text_max_y:
                break
            line_w = _text_width(draw, line, brand_font)
            line_x = margin + (text_max_width - line_w) // 2
            draw.text((line_x, y), line, fill=0, font=brand_font)
            y += line_h + max(2, margin // 6)

    if logo_drawn or cleaned_brand_text:
        draw.line((margin, y, width - margin, y), fill=0, width=1)
        y += max(8, margin // 4)

    for line in _wrap_text(
        draw, "3D PRINT", font=title_font, max_width=text_max_width
    ):
        line_h = _text_height(draw, line, title_font)
        if y + line_h > text_max_y:
            break
        draw.text((margin, y), line, fill=0, font=title_font)
        y += line_h + max(4, margin // 6)

    # Patron name is primary visual information for human pickup sorting.
    sort_name = _format_sort_name(job.user_name)
    for line in _wrap_text(
        draw,
        shorten(sort_name, width=44, placeholder="..."),
        font=name_font,
        max_width=text_max_width,
    ):
        line_h = _text_height(draw, line, name_font)
        if y + line_h > text_max_y:
            break
        draw.text((margin, y), line, fill=0, font=name_font)
        y += line_h + max(6, margin // 4)

    draw.line((margin, y, width - margin, y), fill=0, width=2)
    y += max(8, margin // 4)

    detail_lines = [
        shorten(job.file_name, width=62, placeholder="..."),
        job.category_label,
        f"Printed: {date.today().strftime('%b %d, %Y')}",
    ]
    if job.course_number:
        detail_lines.append(shorten(job.course_number, width=42, placeholder="..."))
    if job.instructor:
        detail_lines.append(shorten(job.instructor, width=42, placeholder="..."))
    if job.department:
        detail_lines.append(shorten(job.department, width=42, placeholder="..."))
    if job.pi_name:
        detail_lines.append(shorten(job.pi_name, width=42, placeholder="..."))

    for raw_line in detail_lines:
        for line in _wrap_text(
            draw, raw_line, font=body_font, max_width=text_max_width
        ):
            line_h = _text_height(draw, line, body_font)
            if y + line_h > text_max_y:
                break
            draw.text((margin, y), line, fill=0, font=body_font)
            y += line_h + max(6, margin // 4)
        if y >= text_max_y:
            break

    id_font_to_use = id_font
    id_w = _text_width(draw, id_line, id_font_to_use)
    while id_w > text_width_left_of_qr and id_font_to_use.size > 14:
        id_font_to_use = _load_font(id_font_to_use.size - 1)
        id_w = _text_width(draw, id_line, id_font_to_use)
    draw.text((margin, id_y), id_line, fill=0, font=id_font_to_use)

    qr = build_qr_image(qr_payload, size=qr_size)
    image.paste(qr, (qr_x, qr_y))
    draw.rectangle(
        (qr_x - 1, qr_y - 1, qr_x + qr_size, qr_y + qr_size), outline=0, width=1
    )

    return image


def _cups_command_for_image(
    *,
    queue_name: str,
    file_path: str,
    media: str,
    orientation: str,
    extra_options: str,
) -> list[str]:
    cmd = [
        "lp",
        "-d",
        queue_name,
        "-o",
        f"PageSize={media}",
        "-o",
        "MediaType=Labels",
        "-o",
        "fit-to-page",
        file_path,
    ]
    raw_options = [item.strip() for item in extra_options.split(",") if item.strip()]
    for option in raw_options:
        cmd.extend(["-o", option])
    return cmd


def cleanup_saved_labels(output_dir: str, *, keep_days: int) -> int:
    target_dir = Path(output_dir)
    if not target_dir.exists():
        return 0

    safe_keep_days = max(1, int(keep_days))
    cutoff_day = date.today() - timedelta(days=safe_keep_days - 1)
    removed = 0
    for png_file in target_dir.glob("*.png"):
        try:
            modified_day = datetime.fromtimestamp(png_file.stat().st_mtime).date()
            if modified_day < cutoff_day:
                png_file.unlink()
                removed += 1
        except OSError:
            continue
    return removed


def create_and_print_label(
    *,
    job,
    completion_url: str,
    output_dir: str,
    mode: str,
    queue_name: str,
    stock: str,
    dpi: int,
    qr_payload_mode: str,
    qr_size_inch: float,
    label_orientation: str,
    brand_text: str,
    brand_logo_path: str,
    cups_media: str,
    cups_extra_options: str,
    save_label_files: bool,
    cleanup_keep_days: int = 1,
) -> dict:
    qr_payload = completion_url if qr_payload_mode == "url" else job.label_code
    image = _render_label_image(
        job,
        qr_payload,
        stock=stock,
        dpi=dpi,
        qr_size_inch=qr_size_inch,
        orientation=label_orientation,
        brand_text=brand_text,
        brand_logo_path=brand_logo_path,
    )
    result = {
        "image_path": "",
        "printed": False,
        "message": f"Label image generated for {stock}.",
    }

    persistent_file_path: Path | None = None
    if save_label_files:
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        cleanup_saved_labels(str(output_path), keep_days=cleanup_keep_days)
        persistent_file_path = output_path / f"{job.label_code}.png"
        image.save(persistent_file_path)
        result["image_path"] = str(persistent_file_path)

    if mode != "cups":
        if save_label_files:
            result["message"] = (
                f"Label image generated for {stock} (mock mode, not sent to printer)."
            )
        else:
            result["message"] = (
                f"Label prepared for {stock} (mock mode, not sent to printer and not saved to disk)."
            )
        log.info(
            "Label mode is '%s' (not cups) — skipping print. %s",
            mode,
            result["message"],
        )
        return result

    if not queue_name:
        result["message"] = (
            "LABEL_PRINTER_QUEUE is not configured, so printing was skipped."
        )
        log.warning("%s", result["message"])
        return result

    temp_file_path: Path | None = None
    file_path_for_print = ""
    if persistent_file_path:
        file_path_for_print = str(persistent_file_path)
    else:
        with tempfile.NamedTemporaryFile(
            prefix=f"{job.label_code}-", suffix=".png", delete=False
        ) as temp_file:
            temp_file_path = Path(temp_file.name)
        image.save(temp_file_path)
        file_path_for_print = str(temp_file_path)

    cups_cmd = _cups_command_for_image(
        queue_name=queue_name,
        file_path=file_path_for_print,
        media=cups_media,
        orientation=label_orientation,
        extra_options=cups_extra_options,
    )
    log.info("Sending label to CUPS: %s", " ".join(cups_cmd))
    try:
        process = subprocess.run(
            cups_cmd,
            check=True,
            capture_output=True,
            text=True,
        )
        result["printed"] = True
        result["message"] = process.stdout.strip() or "Label sent to printer queue."
        log.info("CUPS print succeeded: %s", result["message"])
    except Exception as exc:  # noqa: BLE001
        result["message"] = f"Printing failed: {exc}"
        log.error("CUPS print failed: %s", exc)
    finally:
        if temp_file_path and temp_file_path.exists():
            try:
                temp_file_path.unlink()
            except OSError:
                pass

    return result
