"""Audit wheel versions against the tuned-builds version-style rule.

The rule and the reasoning behind it are in docs/VERSIONING.md: a tuned wheel's
local version is ``<variant>.cu<cuda>.tuning.<N>`` with ``N`` a numeric,
non-zero-padded segment. This tool classifies every wheel it is given, flags
problems the rule exists to prevent, and can render the result as markdown.

Sources of wheels (choose one):
  * ``--owner`` (default): query GitHub releases with the ``gh`` CLI.
  * ``--input FILE``: a TSV saved earlier (repo, tag, published, filename).
  * ``--files PATH...``: local wheel files, e.g. a fresh ``dist/*.whl``.

Exit status is 1 when ``--strict`` is given and any finding was reported, or
when ``--files`` was used and a wheel is not ``conforming`` (so it can gate a
release script).
"""

import argparse
import logging
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import unquote

from packaging.utils import InvalidWheelFilename, parse_wheel_filename
from packaging.version import Version

logger = logging.getLogger(__name__)

CONFORMING = "conforming"
LEGACY_V = "legacy-v"
PRE_MARKER = "pre-marker"
PLATFORM_ONLY = "platform-only"
NO_LOCAL = "no-local"
OTHER = "other"

# An optional leading segment such as ``g<sha>`` / ``git<sha>`` may come from
# setuptools_scm (vllm) before the tuned part.
SCM_PREFIX = r"(?:[a-z][a-z0-9]*\.)*"
TUNED_PART = r"[a-z][a-z0-9]*\.cu[0-9]+\.tuning\."
CONFORMING_RE = re.compile(rf"^{SCM_PREFIX}{TUNED_PART}(0|[1-9][0-9]*)$")
LEGACY_V_RE = re.compile(rf"^{SCM_PREFIX}{TUNED_PART}v[0-9]+$")
PLATFORM_ONLY_RE = re.compile(r"^cu[0-9]+$")
TUNED_VARIANT_RE = re.compile(r"(^|\.)(gb10|rtx40|rtx50)(\.|$)")

CLASS_MEANING = {
    CONFORMING: "current rule (tuning.N)",
    LEGACY_V: "legacy tuning.vN (fused counter; kept, not renamed)",
    PRE_MARKER: "tuned variant but no tuning counter",
    PLATFORM_ONLY: "platform tag only, e.g. +cu133 (upstream style)",
    NO_LOCAL: "no local version label",
    OTHER: "does not match any known scheme",
}


@dataclass
class WheelRecord:
    """One published (or local) wheel file and what its version says."""

    repo: str
    tag: str
    published: str
    filename: str
    dist: str
    token: str
    version: Version

    @property
    def local(self) -> str:
        """Return the normalized local label, or "" when there is none."""
        return self.version.local or ""

    @property
    def classification(self) -> str:
        """Return which version scheme this wheel's local label follows."""
        return WheelVersionAudit.classify(self.local)


class WheelVersionAudit:
    """Classify wheels and report version-style findings.

    Equivalent in intent to ``gpu_tuned_local_version`` in tuned-common.sh, which
    builds the label; this class checks labels that already exist.
    """

    def __init__(self, records: list[WheelRecord]) -> None:
        """Hold the wheels to audit, in the order given."""
        self.records = records

    @staticmethod
    def classify(local: str) -> str:
        """Return the scheme name for a normalized local version label."""
        if not local:
            return NO_LOCAL
        if CONFORMING_RE.match(local):
            return CONFORMING
        if LEGACY_V_RE.match(local):
            return LEGACY_V
        if PLATFORM_ONLY_RE.match(local):
            return PLATFORM_ONLY
        if TUNED_VARIANT_RE.search(local):
            return PRE_MARKER
        return OTHER

    @classmethod
    def parse_wheel(
        cls, repo: str, tag: str, published: str, filename: str
    ) -> Optional[WheelRecord]:
        """Build a record from a wheel filename, or None if it is not a wheel."""
        try:
            name, version, _build, _tags = parse_wheel_filename(filename)
        except InvalidWheelFilename:
            logger.warning("skipping unparsable wheel filename: %s", filename)
            return None
        token = filename.split("-")[1]
        return WheelRecord(repo, tag, published, filename, str(name), token, version)

    @classmethod
    def from_tsv(cls, path: Path) -> "WheelVersionAudit":
        """Load records from a TSV of repo, tag, published, filename."""
        records: list[WheelRecord] = []
        for line in path.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) != 4:
                logger.warning("skipping malformed TSV line: %r", line)
                continue
            record = cls.parse_wheel(*fields)
            if record is not None:
                records.append(record)
        return cls(records)

    @classmethod
    def from_files(cls, paths: list[Path]) -> "WheelVersionAudit":
        """Load records from local wheel files (no repo, tag or date)."""
        records = []
        for path in paths:
            record = cls.parse_wheel("(local)", "", "", path.name)
            if record is not None:
                records.append(record)
        return cls(records)

    @staticmethod
    def _gh(args: list[str]) -> list[str]:
        """Run the gh CLI and return stdout lines; empty on any failure."""
        result = subprocess.run(
            ["gh", *args], capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            logger.warning("gh %s failed: %s", " ".join(args[:2]), result.stderr[:120])
            return []
        return result.stdout.splitlines()

    @classmethod
    def from_github(cls, owners: list[str]) -> "WheelVersionAudit":
        """Query every repo of the given owners for wheel release assets."""
        records: list[WheelRecord] = []
        jq_assets = (
            ".[] | .tag_name as $t | .published_at as $d | .assets[] "
            '| select(.name|endswith(".whl")) | [$t, $d, .name] | @tsv'
        )
        for owner in owners:
            repo_args = ["repo", "list", owner, "--limit", "200"]
            for name in cls._gh([*repo_args, "--json", "name", "--jq", ".[].name"]):
                repo = f"{owner}/{name}"
                rows = cls._gh(
                    ["api", f"repos/{repo}/releases", "--paginate", "--jq", jq_assets]
                )
                for row in rows:
                    fields = row.split("\t")
                    if len(fields) == 3:
                        record = cls.parse_wheel(repo, *fields)
                        if record is not None:
                            records.append(record)
        return cls(records)

    def to_tsv(self) -> str:
        """Return the records as TSV, suitable for ``--input`` later."""
        rows = [
            "\t".join([r.repo, r.tag, r.published, r.filename]) for r in self.records
        ]
        return "\n".join(rows) + "\n"

    @staticmethod
    def wheel_findings(record: WheelRecord) -> list[str]:
        """Return problems with one wheel: normalization and tag/version drift."""
        findings = []
        if record.token != str(record.version):
            findings.append(
                f"filename version '{record.token}' is not the normalized form "
                f"'{record.version}'"
            )
        tag_version = unquote(record.tag).removeprefix("v")
        if "+" in tag_version and tag_version != str(record.version):
            findings.append(
                f"tag '{record.tag}' disagrees with wheel version '{record.version}'"
            )
        return findings

    def ordering_findings(self) -> list[str]:
        """Return cases where a newer release has a lower version than an older one.

        Grouped per distribution and ordered by publish date, so a build that
        ``pip install -U`` would rank below an older one is reported.
        """
        by_dist: dict[str, list[WheelRecord]] = {}
        for record in self.records:
            if record.published:
                by_dist.setdefault(record.dist, []).append(record)
        findings = []
        for dist, records in sorted(by_dist.items()):
            records.sort(key=lambda r: r.published)
            for older, newer in zip(records, records[1:]):
                if newer.version < older.version:
                    findings.append(
                        f"{dist}: {newer.version} ({newer.published[:10]}) sorts "
                        f"below the older {older.version} ({older.published[:10]})"
                    )
        return findings

    def duplicate_findings(self) -> list[str]:
        """Return wheel filenames attached to more than one release of a repo."""
        seen: dict[tuple[str, str], list[str]] = {}
        for record in self.records:
            seen.setdefault((record.repo, record.filename), []).append(record.tag)
        return [
            f"{repo}: {name} is attached to {len(tags)} releases: {', '.join(tags)}"
            for (repo, name), tags in sorted(seen.items())
            if len(tags) > 1
        ]

    def all_findings(self) -> list[str]:
        """Return every finding: per-wheel, ordering and duplicates."""
        findings = []
        for record in self.records:
            findings += [f"{record.filename}: {f}" for f in self.wheel_findings(record)]
        return findings + self.ordering_findings() + self.duplicate_findings()

    def summary(self) -> dict[str, int]:
        """Return how many wheels fall in each classification."""
        counts: dict[str, int] = {}
        for record in self.records:
            counts[record.classification] = counts.get(record.classification, 0) + 1
        return counts

    def render_markdown(self) -> str:
        """Render the summary, per-wheel table and findings as markdown."""
        lines = ["| class | wheels | meaning |", "|---|---|---|"]
        for name, count in sorted(self.summary().items()):
            lines.append(f"| `{name}` | {count} | {CLASS_MEANING[name]} |")
        lines += [
            "",
            "| repo | tag | published | wheel | class |",
            "|---|---|---|---|---|",
        ]
        for r in sorted(self.records, key=lambda r: (r.repo, r.published, r.filename)):
            lines.append(
                f"| {r.repo} | `{r.tag}` | {r.published[:10]} | `{r.filename}` "
                f"| {r.classification} |"
            )
        findings = self.all_findings()
        lines += ["", f"Findings: {len(findings)}"] + [f"- {f}" for f in findings]
        return "\n".join(lines) + "\n"

    @classmethod
    def main(cls, argv: Optional[list[str]] = None) -> int:
        """Run the audit from the command line and return the exit status."""
        parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
        parser.add_argument("--owner", action="append", default=None)
        parser.add_argument("--input", type=Path)
        parser.add_argument("--files", nargs="+", type=Path)
        parser.add_argument("--save-tsv", type=Path)
        parser.add_argument("--markdown", action="store_true")
        parser.add_argument("--strict", action="store_true")
        args = parser.parse_args(argv)

        if args.files:
            audit = cls.from_files(args.files)
        elif args.input:
            audit = cls.from_tsv(args.input)
        else:
            audit = cls.from_github(args.owner or ["zbrad", "ZBrad-LLC"])
        if args.save_tsv:
            args.save_tsv.write_text(audit.to_tsv())

        findings = audit.all_findings()
        if args.markdown:
            print(audit.render_markdown(), end="")
        else:
            for name, count in sorted(audit.summary().items()):
                print(f"{count:3d}  {name:14s} {CLASS_MEANING[name]}")
            for finding in findings:
                print(f"FINDING: {finding}")
        not_conforming = bool(args.files) and any(
            r.classification != CONFORMING for r in audit.records
        )
        return 1 if (args.strict and findings) or not_conforming else 0


if __name__ == "__main__":
    logging.basicConfig(level=logging.WARNING)
    sys.exit(WheelVersionAudit.main())
