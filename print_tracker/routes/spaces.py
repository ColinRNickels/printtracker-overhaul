from flask import Blueprint, abort, redirect, url_for

from ..routes.patron import handle_registration
from ..services.spaces import get_default_space, get_space


bp = Blueprint("spaces", __name__)


@bp.route("/<space_slug>", methods=["GET", "POST"])
@bp.route("/<space_slug>/register", methods=["GET", "POST"])
def register_space(space_slug: str):
    if not get_space(space_slug):
        abort(404)
    return handle_registration(space_slug)


@bp.route("/<space_slug>/staff")
def redirect_space_staff(space_slug: str):
    if not get_space(space_slug):
        abort(404)
    return redirect(url_for("staff.dashboard"))


@bp.route("/<space_slug>/staff/s/<label_code>")
def redirect_space_staff_shortcut(space_slug: str, label_code: str):
    if not get_space(space_slug):
        abort(404)
    return redirect(url_for("staff.scan_shortcut", label_code=label_code))