"""Structure checks for docs/upstream-vs-tuned-versions.json.

The file is a reference snapshot whose value is its shape, so these tests pin the
shape and the internal consistency (not the values, which go stale).
"""

import json
import re
from pathlib import Path

import pytest
from wheel_version_audit import DATED, WheelVersionAudit

DOC = (
    Path(__file__).resolve().parent.parent / "docs" / "upstream-vs-tuned-versions.json"
)
REL_VALUES = {"behind", "ahead", "at"}
LINEAGE = {"default-branch", "release-branch"}
RELIABILITY = {"reliable", "noisy", "unverified", "none"}


@pytest.fixture(scope="module")
def doc() -> dict:
    return json.loads(DOC.read_text())


def test_doc_top_level_keys_present(doc: dict) -> None:
    required = {"schema", "as_of", "status", "scheme", "provenance", "method", "repos"}
    assert required <= set(doc)


def test_doc_covers_each_repo_once(doc: dict) -> None:
    names = [r["repo"] for r in doc["repos"]]
    assert len(names) == len(set(names)) == 10


def test_every_expected_block_is_marked_simulated(doc: dict) -> None:
    assert all(r["tuned"]["expected"]["simulated"] is True for r in doc["repos"])


def test_repo_records_have_the_documented_shape(doc: dict) -> None:
    for r in doc["repos"]:
        assert r["kind"] in {"wheel", "native"}, r["repo"]
        assert re.fullmatch(r"[0-9a-f]{12}", r["base"]["sha12"]), r["repo"]
        assert r["comparison"]["relation"] in REL_VALUES, r["repo"]
        assert r["base"]["nearest_tag_reliability"] in RELIABILITY, r["repo"]
        tags = r["upstream"]["tag_scheme"]
        assert tags["tag_lineage"] in LINEAGE, r["repo"]
        assert r["upstream"]["last3_releases"], r["repo"]


def test_newest_stable_tag_matches_its_own_declared_pattern(doc: dict) -> None:
    for r in doc["repos"]:
        scheme = r["upstream"]["tag_scheme"]
        patterns = [re.compile(p) for p in scheme["stable_tag_regexes"]]
        assert any(p.match(scheme["newest_stable_tag"]) for p in patterns), r["repo"]


def test_tag_lineage_agrees_with_the_behind_count(doc: dict) -> None:
    for r in doc["repos"]:
        behind = r["upstream"]["default_branch_vs_newest_stable_tag"]["behind"]
        want = "release-branch" if behind else "default-branch"
        assert r["upstream"]["tag_scheme"]["tag_lineage"] == want, r["repo"]


def test_expected_wheel_labels_follow_the_current_rule(doc: dict) -> None:
    wheels = [r for r in doc["repos"] if r["kind"] == "wheel"]
    assert wheels
    for r in wheels:
        label = r["tuned"]["expected"]["label"]
        assert WheelVersionAudit.classify(label) == DATED, r["repo"]
        assert r["tuned"]["expected"]["tag"].endswith(label), r["repo"]


def test_expected_native_tags_use_the_v0_date_form(doc: dict) -> None:
    natives = [r for r in doc["repos"] if r["kind"] == "native"]
    assert natives
    for r in natives:
        tag = r["tuned"]["expected"]["tag"]
        assert re.match(r"^v0\.[1-9][0-9]{7}\.(0|[1-9][0-9]*)-", tag), r["repo"]
