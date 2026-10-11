"""Tests for wheel_version_audit.WheelVersionAudit."""

import subprocess
from pathlib import Path

import pytest
from packaging.version import Version
from wheel_version_audit import (
    CONFORMING,
    DATED,
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
        ("gb10.cu134.20261010", DATED),
        ("gb10.cu134.20261010.1", DATED),
        ("g44a0a3c96.gb10.cu134.20261010", DATED),
        ("gb10.cu134.20261010.0", PRE_MARKER),
        ("gb10.cu134.20261010.01", PRE_MARKER),
        ("gb10.cu134.20260230", PRE_MARKER),
        ("gb10.cu134.02061010", PRE_MARKER),
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


def test_main_files_mode_passes_for_dated_wheel(tmp_path: Path) -> None:
    wheel = tmp_path / ("pkg-1.0+gb10.cu134.20261010" + TAIL)
    wheel.write_text("")
    assert WheelVersionAudit.main(["--files", str(wheel)]) == 0


@pytest.mark.parametrize(
    "label", ["gb10.cu134.20261010", "gb10.cu134.20261010.1", "gb10.cu134.20261010.12"]
)
def test_dated_label_is_already_in_normalized_form(label: str) -> None:
    """A wheel filename carries the normalized version, so the label must be it."""
    version = f"0.7.0+{label}"
    assert str(Version(version)) == version


def test_dated_labels_sort_above_every_older_scheme_and_in_build_order() -> None:
    """The date form must outrank the counter forms already published."""
    base = "0.7.0+gb10.cu134."
    ascending = [
        "tuning.v149",
        "tuning.v34",
        "tuning.35",
        "tuning.62",
        "20261010",
        "20261010.1",
        "20261010.2",
        "20261010.10",
        "20261011",
    ]
    versions = [Version(base + label) for label in ascending]
    assert versions == sorted(versions)
    assert Version("0.7.0+gb10") < Version(base + "20261010")
    assert Version(base + "20261010.2") < Version(base + "20261010.10")


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "local",
    [
        "gb10.cu134.20261011",
        "gb10.cu134.20261011.2",
        "g97106f879.gb10.cu133.20261011",
        "gb10.cu134.20260230",
        "gb10.cu134.20261011.0",
        "gb10.cu134.02061011",
        "gb10.cu134.tuning.62",
        "gb10.cu134.tuning.v34",
        "cu133",
        "gb10",
        "gb10.cu134.2026101",
    ],
)
def test_shell_wheel_label_check_agrees_with_audit_dated_class(local: str) -> None:
    """gpu_tuned_check_wheel_label (bash) accepts exactly what DATED accepts."""
    wheel = f"torch-2.15.0+{local}-cp314-cp314-linux_aarch64.whl"
    script = (
        f"source '{REPO_ROOT}/tuned-common.sh'; "
        f"gpu_tuned_check_wheel_label '{wheel}'"
    )
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert (result.returncode == 0) == (WheelVersionAudit.classify(local) == DATED)
