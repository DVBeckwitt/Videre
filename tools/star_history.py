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
    paths = root.findall(".//{http://www.w3.org/2000/svg}path")
    if not paths:
        raise ValueError("assets/icon.svg no longer contains the Videre logo paths")
    geometry = []
    for path in paths:
        data, fill = path.get("d", ""), path.get("fill", "")
        if not re.fullmatch(r"[MmZzLlHhVvCcSsQqTtAa0-9eE.,+\s-]+", data):
            raise ValueError("logo contains unsupported SVG path data")
        if not re.fullmatch(r"#[0-9a-fA-F]{6}", fill):
            raise ValueError("logo contains an unsupported fill color")
        geometry.append((data, fill))
    return geometry


def axis_scale(total):
    """Choose integer ticks and place the top tick just above the data."""
    desired_step = max(1, (total + 4) // 5)
    magnitude = 10 ** (len(str(desired_step)) - 1)
    step = next(multiplier * magnitude for multiplier in (1, 2, 5, 10)
                if multiplier * magnitude >= desired_step)
    return step, max(4, (total // step + 1) * step)


def render_svg(snapshot):
    points = cumulative_series(snapshot)
    start, end, total = points[0][0], points[-1][0], points[-1][1]
    step, ceiling = axis_scale(total)
    left = max(30, 12 + 7 * len(f"{ceiling:,}"))
    right, top, bottom = 410, 33, 124
    x = lambda stamp: left + (stamp - start) / (end - start) * (right - left)
    y = lambda count: bottom - count / ceiling * (bottom - top)
    line = f"M {left} {bottom}"
    for stamp, count in points[1:]:
        line += f" H {x(stamp):.2f} V {y(count):.2f}"
    area = f"{line} L {right} {bottom} Z"
    logo = "".join(f'<path d="{data}" fill="{fill}"/>' for data, fill in logo_geometry())
    repository = escape(snapshot["repository"])
    fetched = snapshot["fetched_at"]
    total_label = f'{total:,} {"star" if total == 1 else "stars"}'
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="420" height="150" viewBox="0 0 420 150" role="img" aria-labelledby="title description">',
        f'<title id="title">Videre star history — {total_label}</title>',
        f'<desc id="description">Cumulative daily star counts for {repository}, from GitHub aggregate star history, fetched {fetched} UTC. Daily buckets use GitHub boundaries. Historical totals before removed stars are not preserved.</desc>',
        '<style>',
        '.heading { fill: #242037; } .tick { fill: #5d586f; }',
        '@media (prefers-color-scheme: dark) { .heading { fill: #f4f1ff; } .tick { fill: #a9a4bc; } }',
        '</style>',
        '<g font-family="Segoe UI, Helvetica, Arial, sans-serif">',
        f'<g transform="translate({left - 7} -1) scale(.065)">{logo}</g>',
        f'<text x="{left + 25}" y="20" class="heading" font-size="15" font-weight="600">Star history</text>',
        f'<text x="{right}" y="20" class="heading" font-size="15" font-weight="600" text-anchor="end">{total_label}</text>',
    ]
    for count in range(0, ceiling + 1, step):
        height = y(count)
        parts += [
            f'<line x1="{left}" y1="{height:.2f}" x2="{right}" y2="{height:.2f}" stroke="#827a9c" stroke-opacity=".22"/>',
            f'<text x="{left - 6}" y="{height + 4:.2f}" class="tick" font-size="11" text-anchor="end">{count:,}</text>',
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
    date_ticks = [start]
    for stamp in stamps[1:-1]:
        if x(stamp) - x(date_ticks[-1]) >= 64 and right - x(stamp) >= 64:
            date_ticks.append(stamp)
    date_ticks.append(end)
    previous_label = None
    for index, stamp in enumerate(date_ticks):
        tick_date = datetime.fromtimestamp(stamp, timezone.utc)
        month_label = MONTHS[tick_date.month - 1]
        label = f"{month_label} {tick_date.year}" if span > 180 * DAY else f"{month_label} {tick_date.day:02}"
        if label == previous_label:
            continue
        previous_label = label
        anchor = "start" if index == 0 else "end" if index == len(date_ticks) - 1 else "middle"
        parts.append(f'<text x="{x(stamp):.2f}" y="142" class="tick" font-size="11" text-anchor="{anchor}">{label}</text>')
    parts += [
        f'<path d="{area}" fill="#7c3aed" fill-opacity=".14"/>',
        f'<path d="{line}" fill="none" stroke="#9b64f4" stroke-width="2" stroke-linejoin="round"/>',
        f'<circle cx="{right}" cy="{y(total):.2f}" r="3" fill="#9b64f4"/>',
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
