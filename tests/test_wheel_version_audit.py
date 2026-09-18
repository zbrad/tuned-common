"""Tests for wheel_version_audit.WheelVersionAudit."""

from pathlib import Path

import pytest
from wheel_version_audit import (
    CONFORMING,
    LEGACY_V,
    NO_LOCAL,
    OTHER,
    PLATFORM_ONLY,
    PRE_MARKER,
    WheelVersionAudit,
)

TAIL = "-py3-none-any.whl"


def _audit(*rows: tuple[str, str, str]) -> WheelVersionAudit:
    """Build an audit from (tag, published, filename) rows in one repo."""
    records = [WheelVersionAudit.parse_wheel("o/r", t, d, f) for t, d, f in rows]
    return WheelVersionAudit([r for r in records if r is not None])


@pytest.mark.parametrize(
    ("local", "expected"),
    [
        ("gb10.cu134.tuning.149", CONFORMING),
        ("g44a0a3c96.gb10.cu134.tuning.539", CONFORMING),
        ("gb10.cu134.tuning.0", CONFORMING),
        ("gb10.cu134.tuning.v149", LEGACY_V),
        ("g44a0a3c96.gb10.cu134.tuning.v539", LEGACY_V),
        ("gb10.cu133", PRE_MARKER),
        ("git283e075.gb10.cu133", PRE_MARKER),
        ("cu133", PLATFORM_ONLY),
        ("", NO_LOCAL),
        ("vendor.build7", OTHER),
    ],
)
def test_classify_known_schemes(local: str, expected: str) -> None:
    assert WheelVersionAudit.classify(local) == expected


def test_classify_rejects_zero_padded_counter_as_conforming() -> None:
    assert WheelVersionAudit.classify("gb10.cu134.tuning.007") != CONFORMING


def test_parse_wheel_returns_none_for_non_wheel_name() -> None:
    assert WheelVersionAudit.parse_wheel("o/r", "v1", "", "not-a-wheel.txt") is None


def test_wheel_findings_flags_unnormalized_filename_version() -> None:
    audit = _audit(("v1", "", "pkg-1.0+GB10" + TAIL))
    findings = WheelVersionAudit.wheel_findings(audit.records[0])
    assert any("not the normalized form" in f for f in findings)


def test_wheel_findings_flags_dashed_tag_against_dotted_wheel() -> None:
    audit = _audit(
        ("v1.0+gb10.cu134.tuning-v3", "", "pkg-1.0+gb10.cu134.tuning.v3" + TAIL)
    )
    findings = WheelVersionAudit.wheel_findings(audit.records[0])
    assert any("disagrees with wheel version" in f for f in findings)


def test_wheel_findings_clean_when_tag_matches_wheel() -> None:
    audit = _audit(
        ("v1.0+gb10.cu134.tuning.3", "", "pkg-1.0+gb10.cu134.tuning.3" + TAIL)
    )
    assert WheelVersionAudit.wheel_findings(audit.records[0]) == []


def test_ordering_findings_reports_newer_release_with_lower_version() -> None:
    audit = _audit(
        ("v8", "2026-08-07T00:00:00Z", "pkg-8.4.dev7+gb10" + TAIL),
        ("v0", "2026-09-18T00:00:00Z", "pkg-0.29.1rc1+gb10" + TAIL),
    )
    assert len(audit.ordering_findings()) == 1


def test_ordering_findings_accepts_legacy_to_numeric_counter_upgrade() -> None:
    audit = _audit(
        ("a", "2026-09-01T00:00:00Z", "pkg-1.0+gb10.cu134.tuning.v539" + TAIL),
        ("b", "2026-09-20T00:00:00Z", "pkg-1.0+gb10.cu134.tuning.540" + TAIL),
    )
    assert audit.ordering_findings() == []


def test_duplicate_findings_reports_same_wheel_in_two_releases() -> None:
    audit = _audit(
        ("v1", "2026-07-06T00:00:00Z", "pkg-1.0+gb10" + TAIL),
        ("v2", "2026-08-07T00:00:00Z", "pkg-1.0+gb10" + TAIL),
    )
    assert len(audit.duplicate_findings()) == 1


def test_tsv_round_trip_preserves_records(tmp_path: Path) -> None:
    audit = _audit(("v1", "2026-09-18T00:00:00Z", "pkg-1.0+gb10.cu134.tuning.3" + TAIL))
    path = tmp_path / "wheels.tsv"
    path.write_text(audit.to_tsv())
    loaded = WheelVersionAudit.from_tsv(path)
    assert [r.filename for r in loaded.records] == [r.filename for r in audit.records]


def test_main_files_mode_fails_for_non_conforming_wheel(tmp_path: Path) -> None:
    wheel = tmp_path / ("pkg-1.0+gb10.cu134.tuning.v3" + TAIL)
    wheel.write_text("")
    assert WheelVersionAudit.main(["--files", str(wheel)]) == 1


def test_main_files_mode_passes_for_conforming_wheel(tmp_path: Path) -> None:
    wheel = tmp_path / ("pkg-1.0+gb10.cu134.tuning.3" + TAIL)
    wheel.write_text("")
    assert WheelVersionAudit.main(["--files", str(wheel)]) == 0
