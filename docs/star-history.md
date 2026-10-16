# README star history

The README chart combines Videre's logo and colors with GitHub's real daily star
counts. [View the full chart](../assets/star-history.svg) or inspect its
[source snapshot](../assets/star-history.json).

The [Star history workflow](../.github/workflows/star-history.yml) refreshes the
chart daily at 11:37 UTC, and can also be run manually from
[GitHub Actions](https://github.com/DVBeckwitt/Videre/actions/workflows/star-history.yml).
Scheduled runs can be delayed by GitHub. The chart displays its last refresh date;
if a fetch or validation fails, the previous committed chart remains available.

## Data and interpretation

The generator retrieves every page of GitHub's
[repository star history API](https://docs.github.com/en/rest/activity/starring?apiVersion=2026-03-10#get-repository-star-history).
It stores only aggregate weekly and daily counts, the repository name, source URL,
and retrieval date. No stargazer identities or credentials are stored.

The line is the cumulative sum of the daily counts returned by GitHub. It uses
steps to show daily changes without inventing intermediate measurements. GitHub
defines the day boundaries; they are not guaranteed to align with UTC. This is
a reconstruction from GitHub's current aggregate history, not an archive of the
headline star count observed on each past date. Removed stars and account changes
can affect the returned history.

## Reproduce or update

Use Python 3.13; no extra packages are required. From the repository root:

```sh
python -m unittest discover -s tools -p test_star_history.py -v
python tools/star_history.py --input assets/star-history.json --output assets/star-history.svg
```

The offline command reproduces the chart from the committed snapshot. To fetch
fresh data and update both generated files:

```sh
python tools/star_history.py
```

The API supports public reads. Set `GH_TOKEN` in the environment if authentication
is needed for rate limits; never put a token in a command argument or tracked file.
The workflow uses GitHub's built-in token. Pull requests run validation with read
access; only the update job on this repository's `master` branch can commit the
two generated assets. Its bot commits do not trigger another Actions run.

Edit `tools/star_history.py` for chart design changes. The play symbol comes from
`assets/icon.svg`. Regenerate the SVG afterward; CI checks that the committed SVG
matches its data and renderer on Linux and Windows.
