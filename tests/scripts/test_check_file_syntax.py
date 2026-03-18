"""Unit tests for lockpick-workflow/scripts/check-file-syntax.py.

Tests cover:
  - check_bash: detects syntax errors in .sh files, passes clean files
  - check_yaml: detects conflict markers / malformed YAML, passes clean YAML
               including CloudFormation custom tags
  - check_json: detects malformed JSON, passes valid JSON
  - git_tracked_files: returns only files matching the given suffix

These tests import the module directly (via importlib) since the script filename
contains hyphens.
"""

from __future__ import annotations

import importlib.util
import subprocess
import textwrap
from pathlib import Path
from types import ModuleType

import pytest

# ---------------------------------------------------------------------------
# Module loading — filename has hyphens so we use importlib
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "plugins" / "dso" / "scripts" / "check-file-syntax.py"


def _load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("check_file_syntax", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


@pytest.fixture(scope="module")
def cfs() -> ModuleType:
    """Return the check-file-syntax module, skipping all tests if absent."""
    if not SCRIPT_PATH.exists():
        pytest.skip(f"Script not found: {SCRIPT_PATH}")
    return _load_module()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _git_init(path: Path) -> None:
    """Initialise a bare git repo so git ls-files works."""
    subprocess.run(["git", "init", str(path)], capture_output=True, check=True)
    subprocess.run(
        ["git", "-C", str(path), "config", "user.email", "test@test.com"],
        capture_output=True,
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(path), "config", "user.name", "Test"],
        capture_output=True,
        check=True,
    )


def _git_add(path: Path, *files: Path) -> None:
    """Stage files so git ls-files --cached returns them."""
    subprocess.run(
        ["git", "-C", str(path), "add", *[str(f) for f in files]],
        capture_output=True,
        check=True,
    )


# ---------------------------------------------------------------------------
# Tests for git_tracked_files
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestGitTrackedFiles:
    """git_tracked_files returns only staged files matching the requested suffixes."""

    def test_returns_staged_files_matching_suffix(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        sh_file = tmp_path / "script.sh"
        py_file = tmp_path / "helper.py"
        sh_file.write_text("#!/usr/bin/env bash\necho hi\n")
        py_file.write_text("print('hi')\n")
        _git_add(tmp_path, sh_file, py_file)

        result = cfs.git_tracked_files(tmp_path, (".sh",))
        assert sh_file in result
        assert py_file not in result

    def test_excludes_files_with_wrong_suffix(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        json_file = tmp_path / "config.json"
        json_file.write_text("{}\n")
        _git_add(tmp_path, json_file)

        result = cfs.git_tracked_files(tmp_path, (".yml", ".yaml"))
        assert json_file not in result

    def test_returns_empty_for_empty_repo(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        result = cfs.git_tracked_files(tmp_path, (".sh",))
        assert result == []

    def test_returns_sorted_paths(self, tmp_path: Path, cfs: ModuleType) -> None:
        _git_init(tmp_path)
        b_file = tmp_path / "b.sh"
        a_file = tmp_path / "a.sh"
        b_file.write_text("#!/usr/bin/env bash\n")
        a_file.write_text("#!/usr/bin/env bash\n")
        _git_add(tmp_path, b_file, a_file)

        result = cfs.git_tracked_files(tmp_path, (".sh",))
        assert result == sorted(result)

    def test_includes_untracked_non_ignored_files(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        """--others flag means untracked (not gitignored) files are also returned."""
        _git_init(tmp_path)
        staged = tmp_path / "staged.sh"
        untracked = tmp_path / "untracked.sh"
        staged.write_text("#!/usr/bin/env bash\necho staged\n")
        untracked.write_text("#!/usr/bin/env bash\necho untracked\n")
        _git_add(tmp_path, staged)
        # untracked is NOT staged — relies on --others to be discovered

        result = cfs.git_tracked_files(tmp_path, (".sh",))
        assert staged in result
        assert untracked in result


# ---------------------------------------------------------------------------
# Tests for check_bash
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestCheckBash:
    """check_bash detects bash syntax errors and passes clean scripts."""

    def test_clean_bash_file_passes(self, tmp_path: Path, cfs: ModuleType) -> None:
        _git_init(tmp_path)
        sh_file = tmp_path / "ok.sh"
        sh_file.write_text("#!/usr/bin/env bash\necho 'hello world'\n")
        _git_add(tmp_path, sh_file)

        errors, count = cfs.check_bash(tmp_path)
        assert errors == []
        assert count == 1

    def test_bash_file_with_syntax_error_reported(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        sh_file = tmp_path / "bad.sh"
        # Unclosed if — bash -n will reject this
        sh_file.write_text("#!/usr/bin/env bash\nif [ -z '' \n")
        _git_add(tmp_path, sh_file)

        errors, count = cfs.check_bash(tmp_path)
        assert len(errors) == 1
        assert "bad.sh" in errors[0]
        assert count == 1

    def test_conflict_markers_cause_bash_error(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        sh_file = tmp_path / "conflict.sh"
        sh_file.write_text(
            "#!/usr/bin/env bash\n"
            "<<<<<<< HEAD\n"
            "echo 'ours'\n"
            "=======\n"
            "echo 'theirs'\n"
            ">>>>>>> branch\n"
        )
        _git_add(tmp_path, sh_file)

        errors, count = cfs.check_bash(tmp_path)
        # bash -n will flag the conflict markers as syntax errors
        assert len(errors) >= 1
        assert count == 1

    def test_no_sh_files_returns_zero_count(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        json_file = tmp_path / "data.json"
        json_file.write_text("{}\n")
        _git_add(tmp_path, json_file)

        errors, count = cfs.check_bash(tmp_path)
        assert errors == []
        assert count == 0

    def test_multiple_sh_files_all_checked(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        ok_file = tmp_path / "ok.sh"
        bad_file = tmp_path / "bad.sh"
        ok_file.write_text("#!/usr/bin/env bash\necho ok\n")
        bad_file.write_text("#!/usr/bin/env bash\nif [\n")
        _git_add(tmp_path, ok_file, bad_file)

        errors, count = cfs.check_bash(tmp_path)
        assert count == 2
        assert len(errors) == 1
        assert "bad.sh" in errors[0]


# ---------------------------------------------------------------------------
# Tests for check_yaml
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestCheckYaml:
    """check_yaml detects malformed YAML and passes valid YAML including CF tags."""

    def test_valid_yaml_passes(self, tmp_path: Path, cfs: ModuleType) -> None:
        _git_init(tmp_path)
        yml_file = tmp_path / "config.yml"
        yml_file.write_text("key: value\nlist:\n  - a\n  - b\n")
        _git_add(tmp_path, yml_file)

        errors, count = cfs.check_yaml(tmp_path)
        assert errors == []
        assert count == 1

    def test_cloudformation_tags_pass(self, tmp_path: Path, cfs: ModuleType) -> None:
        """CloudFormation YAML with !Ref, !GetAtt, !Sub must not raise errors."""
        _git_init(tmp_path)
        cf_file = tmp_path / "stack.yaml"
        cf_file.write_text(
            textwrap.dedent(
                """\
                Resources:
                  MyBucket:
                    Type: AWS::S3::Bucket
                    Properties:
                      BucketName: !Sub "${AWS::StackName}-bucket"
                  MyRole:
                    Type: AWS::IAM::Role
                    Properties:
                      RoleName: !Ref MyBucket
                Outputs:
                  BucketArn:
                    Value: !GetAtt MyBucket.Arn
                """
            )
        )
        _git_add(tmp_path, cf_file)

        errors, count = cfs.check_yaml(tmp_path)
        assert errors == [], f"CloudFormation YAML should pass, got: {errors}"
        assert count == 1

    def test_conflict_markers_cause_yaml_error(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        yml_file = tmp_path / "conflict.yml"
        yml_file.write_text(
            "key: value\n"
            "<<<<<<< HEAD\n"
            "other: ours\n"
            "=======\n"
            "other: theirs\n"
            ">>>>>>> branch\n"
        )
        _git_add(tmp_path, yml_file)

        errors, _ = cfs.check_yaml(tmp_path)
        assert len(errors) >= 1
        assert "conflict.yml" in errors[0]

    def test_malformed_yaml_reported(self, tmp_path: Path, cfs: ModuleType) -> None:
        _git_init(tmp_path)
        yml_file = tmp_path / "bad.yml"
        # Indentation error — tabs mixed with spaces
        yml_file.write_text("key:\n\tvalue: broken\n")
        _git_add(tmp_path, yml_file)

        errors, _ = cfs.check_yaml(tmp_path)
        assert len(errors) >= 1
        assert "bad.yml" in errors[0]

    def test_yaml_extension_also_checked(self, tmp_path: Path, cfs: ModuleType) -> None:
        """Both .yml and .yaml extensions are checked."""
        _git_init(tmp_path)
        yaml_file = tmp_path / "config.yaml"
        yaml_file.write_text("name: test\n")
        _git_add(tmp_path, yaml_file)

        errors, count = cfs.check_yaml(tmp_path)
        assert errors == []
        assert count == 1

    def test_no_yaml_files_returns_zero_count(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        errors, count = cfs.check_yaml(tmp_path)
        assert errors == []
        assert count == 0


# ---------------------------------------------------------------------------
# Tests for check_json
# ---------------------------------------------------------------------------


@pytest.mark.unit
@pytest.mark.scripts
class TestCheckJson:
    """check_json detects malformed JSON and passes valid JSON."""

    def test_valid_json_passes(self, tmp_path: Path, cfs: ModuleType) -> None:
        _git_init(tmp_path)
        json_file = tmp_path / "data.json"
        json_file.write_text('{"key": "value", "list": [1, 2, 3]}\n')
        _git_add(tmp_path, json_file)

        errors, count = cfs.check_json(tmp_path)
        assert errors == []
        assert count == 1

    def test_malformed_json_reported(self, tmp_path: Path, cfs: ModuleType) -> None:
        _git_init(tmp_path)
        json_file = tmp_path / "bad.json"
        json_file.write_text('{"key": "value",}\n')  # trailing comma is invalid
        _git_add(tmp_path, json_file)

        errors, _ = cfs.check_json(tmp_path)
        assert len(errors) == 1
        assert "bad.json" in errors[0]

    def test_conflict_markers_cause_json_error(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        json_file = tmp_path / "conflict.json"
        json_file.write_text(
            '{\n"key": "value"\n<<<<<<< HEAD\n,"a": 1\n=======\n,"b": 2\n>>>>>>> branch\n}\n'
        )
        _git_add(tmp_path, json_file)

        errors, _ = cfs.check_json(tmp_path)
        assert len(errors) >= 1
        assert "conflict.json" in errors[0]

    def test_json_array_passes(self, tmp_path: Path, cfs: ModuleType) -> None:
        _git_init(tmp_path)
        json_file = tmp_path / "list.json"
        json_file.write_text('[1, 2, "three"]\n')
        _git_add(tmp_path, json_file)

        errors, count = cfs.check_json(tmp_path)
        assert errors == []
        assert count == 1

    def test_no_json_files_returns_zero_count(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        errors, count = cfs.check_json(tmp_path)
        assert errors == []
        assert count == 0

    def test_multiple_json_files_all_checked(
        self, tmp_path: Path, cfs: ModuleType
    ) -> None:
        _git_init(tmp_path)
        ok_file = tmp_path / "ok.json"
        bad_file = tmp_path / "bad.json"
        ok_file.write_text('{"valid": true}\n')
        bad_file.write_text("{not valid json\n")
        _git_add(tmp_path, ok_file, bad_file)

        errors, count = cfs.check_json(tmp_path)
        assert count == 2
        assert len(errors) == 1
        assert "bad.json" in errors[0]
