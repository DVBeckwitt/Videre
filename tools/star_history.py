#!/usr/bin/env python3
"""Fetch GitHub's aggregate star history and render Videre's README banner.

No user records or credentials are saved. This reconstructs cumulative counts
from GitHub's returned daily buckets; it is not an archive of historical totals
before stars were removed. Buckets retain the API's epoch plus day offset:
GitHub does not guarantee UTC week/day boundaries. UTC is used only for axis
labels and the fetched_at date. The chart extends through that date's last
second. The checked-in snapshot can be rendered offline, deterministically.
"""

import argparse
from datetime import date, datetime, time, timezone
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPOSITORY = "DVBeckwitt/Videre"
DAY = 86400
PAGE_SIZE = 30
MAX_PAGES = 100
API_VERSION = "2026-03-10"
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def repository_name(value):
    if not isinstance(value, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", value
    ):
        raise ValueError("repository must be an owner/repository name")
    return value


def source_url(repository):
    return f"https://api.github.com/repos/{repository_name(repository)}/stargazers/history"


def validate_weeks(weeks):
    """Validate all buckets before counting or writing any output."""
    if not isinstance(weeks, list):
        raise ValueError("star history must be an array of weekly buckets")
    seen = set()
    for bucket in weeks:
        if not isinstance(bucket, dict) or set(bucket) != {"week", "total", "days"}:
            raise ValueError("each weekly bucket must contain week, total and days")
        week, total, days = bucket["week"], bucket["total"], bucket["days"]
        if type(week) is not int or not 0 <= week <= 253402214400:
            raise ValueError("week must be a supported nonnegative Unix timestamp")
        if type(total) is not int or total < 0:
            raise ValueError("weekly total must be a nonnegative integer")
        if not isinstance(days, list) or len(days) != 7 or any(
            type(count) is not int or count < 0 for count in days
        ):
            raise ValueError("days must contain seven nonnegative integers")
        if sum(days) != total:
            raise ValueError("weekly total does not equal its daily counts")
        if week in seen:
            raise ValueError("duplicate week: the paginated history may have changed")
        seen.add(week)
    ordered = sorted(weeks, key=lambda bucket: bucket["week"])
    # Calendar boundaries can shift with time zones/DST. Do not enforce UTC
    # Sundays or an exact 604800-second interval, but reject missing weeks.
    if any(not 6 * DAY <= b["week"] - a["week"] <= 8 * DAY
           for a, b in zip(ordered, ordered[1:])):
        raise ValueError("star history has missing or overlapping weeks")
    return ordered


def validate_snapshot(snapshot):
    if not isinstance(snapshot, dict) or type(snapshot.get("schema_version")) is not int:
        raise ValueError("snapshot needs an integer schema_version")
    if snapshot["schema_version"] != 1:
        raise ValueError("unsupported star-history snapshot version")
    repository = repository_name(snapshot.get("repository"))
    if snapshot.get("source") != source_url(repository):
        raise ValueError("snapshot source must match its GitHub repository")
    fetched = snapshot.get("fetched_at")
    if not isinstance(fetched, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", fetched):
        raise ValueError("fetched_at must be a UTC date in YYYY-MM-DD format")
    fetched_date = date.fromisoformat(fetched)
    end = int(datetime.combine(fetched_date, time(), timezone.utc).timestamp()) + DAY - 1
    weeks = validate_weeks(snapshot.get("weeks"))
    if any(bucket["week"] > end for bucket in weeks):
        raise ValueError("weekly bucket is later than the snapshot date")
    if any(bucket["week"] + offset * DAY > end and count
           for bucket in weeks for offset, count in enumerate(bucket["days"])):
        raise ValueError("nonzero daily bucket is later than the snapshot date")
    return weeks, end


def fetch_history(repository=DEFAULT_REPOSITORY):
    """Read every page, with finite network and pagination limits."""
    url = source_url(repository)
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": "Videre-star-history",
    }
    token = os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    weeks = []
    for page in range(1, MAX_PAGES + 1):
        request = Request(f"{url}?per_page={PAGE_SIZE}&page={page}", headers=headers)
        with urlopen(request, timeout=30) as response:
            batch = json.load(response)
            has_next = 'rel="next"' in response.headers.get("Link", "")
        validate_weeks(batch)
        if len(batch) > PAGE_SIZE:
            raise ValueError("GitHub returned more weeks than requested")
        if batch != sorted(batch, key=lambda bucket: bucket["week"], reverse=True):
            raise ValueError("GitHub returned weekly pages out of order")
        if weeks and batch and batch[0]["week"] >= weeks[-1]["week"]:
            raise ValueError("GitHub pagination repeated or reordered a week")
        weeks.extend(batch)
        if len(batch) < PAGE_SIZE:
            if has_next:
                raise ValueError("GitHub returned an incomplete page with a next-page link")
            break
    else:
        raise ValueError("star history exceeds the API's 100-page limit; refusing partial data")
    snapshot = {
        "schema_version": 1,
        "repository": repository,
        "fetched_at": datetime.now(timezone.utc).date().isoformat(),
        "source": url,
        "weeks": weeks,
    }
    validate_snapshot(snapshot)
    return snapshot


def cumulative_series(snapshot):
    """Return epoch/count points in order, preserving each reported daily bin."""
    weeks, end = validate_snapshot(snapshot)
    start = min(weeks[0]["week"], end - 1) if weeks else end - DAY
    points = [(start, 0)]
    total = 0
    for bucket in weeks:
        for offset, count in enumerate(bucket["days"]):
            if count:
                total += count
                points.append((bucket["week"] + offset * DAY, total))
    points.append((end, total))
    return points


def logo_geometry():
    """Reuse the actual local brand mark without copying SVG metadata/resources."""
    root = ET.parse(ROOT / "assets" / "icon.svg").getroot()
    path = root.find(".//{http://www.w3.org/2000/svg}path[@id='path1085']")
    if path is None:
        raise ValueError("assets/icon.svg no longer contains the Videre logo path")
    geometry = path.attrib["d"]
    if not re.fullmatch(r"[MmZzLlHhVvCcSsQqTtAa0-9eE.,+\s-]+", geometry):
        raise ValueError("logo contains unsupported SVG path data")
    match = re.search(r"(?:^|;)stroke-width:([0-9.]+)(?:;|$)", path.attrib["style"])
    if not match:
        raise ValueError("logo is missing its stroke width")
    return geometry, float(match[1])


def axis_ceiling(total):
    desired_step = max(total, 1) / 4
    magnitude = 10 ** math.floor(math.log10(desired_step))
    step = next(n * magnitude for n in (1, 2, 4, 5, 10) if n * magnitude >= desired_step)
    return max(1, math.ceil(step)) * 4


def render_svg(snapshot):
    points = cumulative_series(snapshot)
    start, end, total = points[0][0], points[-1][0], points[-1][1]
    ceiling = axis_ceiling(total)
    left, right, top, bottom = 150, 1440, 230, 625
    x = lambda stamp: left + (stamp - start) / (end - start) * (right - left)
    y = lambda count: bottom - count / ceiling * (bottom - top)
    line = f"M {left} {bottom}"
    for stamp, count in points[1:]:
        line += f" H {x(stamp):.2f} V {y(count):.2f}"
    area = f"{line} L {right} {bottom} Z"
    geometry, stroke = logo_geometry()
    repository = escape(snapshot["repository"])
    fetched = snapshot["fetched_at"]
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="800" viewBox="0 0 1600 800" role="img" aria-labelledby="title description">',
        f'<title id="title">Videre star history — {total:,} stars</title>',
        f'<desc id="description">Cumulative daily star counts for {repository}, from GitHub aggregate star history, fetched {fetched} UTC. Daily buckets use GitHub boundaries. Historical totals before removed stars are not preserved.</desc>',
        '<defs>',
        '<linearGradient id="panel" x2="1" y2="1"><stop stop-color="#20274f"/><stop offset="1" stop-color="#171c3a"/></linearGradient>',
        '<linearGradient id="violet"><stop stop-color="#5a00a8"/><stop offset="1" stop-color="#9c1ef5"/></linearGradient>',
        '<linearGradient id="area" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#9c1ef5" stop-opacity=".30"/><stop offset="1" stop-color="#9c1ef5" stop-opacity=".01"/></linearGradient>',
        '<filter id="glow" x="-25%" y="-25%" width="150%" height="150%"><feGaussianBlur stdDeviation="4"/></filter>',
        '</defs>',
        '<rect x="3" y="3" width="1594" height="794" rx="38" fill="#1c2245"/>',
        '<rect x="4" y="4" width="1592" height="792" rx="37" fill="url(#panel)" stroke="#9c1ef5" stroke-opacity=".65" stroke-width="2"/>',
        '<g font-family="Segoe UI, Helvetica, Arial, sans-serif">',
        f'<path d="{geometry}" transform="translate(34 -4) scale(.4)" fill="none" stroke="url(#violet)" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"/>',
        '<text x="225" y="145" fill="#9c1ef5" font-size="90" font-weight="600" letter-spacing="-2">Videre</text>',
        '<path d="M 1092 68 L 1097 85 L 1114 90 L 1097 95 L 1092 112 L 1087 95 L 1070 90 L 1087 85 Z" fill="#cda4ff" opacity=".8"/>',
        '<text x="1450" y="104" fill="#eee9ff" font-size="31" font-weight="600" letter-spacing="6" text-anchor="end">STAR HISTORY</text>',
        f'<text x="1450" y="146" fill="#aaaac7" font-size="22" text-anchor="end">{repository}</text>',
        f'<path d="{geometry}" transform="translate(100 60) scale(1.45)" fill="none" stroke="url(#violet)" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round" opacity=".13"/>',
    ]
    for index in range(5):
        count = ceiling * index // 4
        height = y(count)
        tick_size = min(23, 170 / len(f"{count:,}"))
        parts += [
            f'<line x1="{left}" y1="{height:.2f}" x2="{right}" y2="{height:.2f}" stroke="#a7a8d0" stroke-opacity=".14"/>',
            f'<text x="{left - 24}" y="{height + 7:.2f}" fill="#bfc0d8" font-size="{tick_size:.2f}" text-anchor="end">{count:,}</text>',
        ]
    span = end - start
    if span > 60 * DAY:
        first_month = datetime.fromtimestamp(start, timezone.utc)
        final_month = datetime.fromtimestamp(end, timezone.utc)
        months = range(first_month.year * 12 + first_month.month,
                       final_month.year * 12 + final_month.month)
        stride = max(1, math.ceil(len(months) / 5))
        stamps = [start] + [int(datetime(month // 12, month % 12 + 1, 1, tzinfo=timezone.utc).timestamp())
                            for month in months[::stride]] + [end]
    else:
        stamps = [start + span * index / 3 for index in range(4)]
    previous_label = None
    for index, stamp in enumerate(stamps):
        tick_date = datetime.fromtimestamp(stamp, timezone.utc)
        month_label = MONTHS[tick_date.month - 1]
        label = f"{month_label} {tick_date.year}" if span > 180 * DAY else f"{month_label} {tick_date.day:02}"
        if label == previous_label:
            continue
        previous_label = label
        anchor = "start" if index == 0 else "end" if index == len(stamps) - 1 else "middle"
        parts += [
            f'<line x1="{x(stamp):.2f}" y1="{top}" x2="{x(stamp):.2f}" y2="{bottom}" stroke="#a7a8d0" stroke-opacity=".06"/>',
            f'<text x="{x(stamp):.2f}" y="674" fill="#bfc0d8" font-size="23" text-anchor="{anchor}">{label}</text>',
        ]
    label_y = max(top + 28, y(total) - 27)
    label_size = min(34, 400 / max(len(f"{total:,} stars"), 1))
    parts += [
        f'<path d="{area}" fill="url(#area)"/>',
        f'<path d="{line}" fill="none" stroke="#9c1ef5" stroke-width="9" opacity=".35" filter="url(#glow)"/>',
        f'<path d="{line}" fill="none" stroke="#b347ff" stroke-width="4" stroke-linejoin="round"/>',
        f'<circle cx="{right}" cy="{y(total):.2f}" r="11" fill="#9c1ef5" opacity=".3"/>',
        f'<circle cx="{right}" cy="{y(total):.2f}" r="5" fill="#ead4ff"/>',
        f'<text x="{right}" y="{label_y:.2f}" fill="#eee5ff" font-size="{label_size:.2f}" font-weight="600" text-anchor="end">{total:,} {"star" if total == 1 else "stars"}</text>',
        '<text x="100" y="746" fill="#a3a5c4" font-size="21">GitHub star history · cumulative daily counts</text>',
        f'<text x="1500" y="746" fill="#a3a5c4" font-size="21" text-anchor="end">Updated {fetched} UTC</text>',
        '</g>',
        '</svg>',
    ]
    return "\n".join(parts) + "\n"


def write_outputs(snapshot, output, data_output=None):
    """Finish validation/rendering and stage files before replacing artifacts."""
    contents = {Path(output): render_svg(snapshot)}
    if data_output is not None:
        data_path = Path(data_output)
        if data_path.resolve() == Path(output).resolve():
            raise ValueError("SVG and JSON output paths must be different")
        contents[data_path] = json.dumps(snapshot, indent=2, ensure_ascii=True) + "\n"
    staged = []
    try:
        for destination, content in contents.items():
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                             dir=destination.parent, delete=False) as handle:
                staged.append((Path(handle.name), destination))
                handle.write(content)
        for temporary, destination in staged:
            temporary.replace(destination)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY)
    parser.add_argument("--input", type=Path, help="render a saved JSON snapshot without networking")
    parser.add_argument("--output", type=Path, default=ROOT / "assets" / "star-history.svg")
    parser.add_argument("--data-output", type=Path, help="save fetched data (live mode only)")
    args = parser.parse_args(argv)
    if args.input and args.data_output:
        parser.error("--data-output is only supported when fetching live data")
    try:
        if args.input:
            snapshot = json.loads(args.input.read_text(encoding="utf-8"))
            data_output = None
        else:
            snapshot = fetch_history(args.repository)
            data_output = args.data_output or ROOT / "assets" / "star-history.json"
        write_outputs(snapshot, args.output, data_output)
    except HTTPError as error:
        print(f"Star history refresh failed: GitHub returned HTTP {error.code}.", file=sys.stderr)
        return 1
    except (OSError, URLError, ValueError, ET.ParseError) as error:
        # Do not print request headers, tokens, or arbitrary server error bodies.
        print(f"Star history refresh failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print(f"Wrote {args.output} ({sum(week['total'] for week in snapshot['weeks']):,} stars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
