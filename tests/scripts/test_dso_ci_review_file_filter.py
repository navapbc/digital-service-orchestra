"""RED tests for dso_ci_review.file_filter — pre-filter non-reviewable files.

Testing mode: RED — module does not yet exist; all tests must fail with ImportError.

Story 1608-4d8c-da53-47bc: As a DSO operator, oversized PRs are reviewed via
chunked file-level dispatch with LLM aggregation.
Task 07bb-5491-9d49-4dc5: S7.T1 RED unit tests for file_filter.py

RED marker: tests/scripts/test_dso_ci_review_file_filter.py [test_linguist_generated_files_are_filtered_out]

Behavioral contracts under test (DD1):
1. linguist-generated tagged files in .gitattributes are filtered OUT
2. linguist-vendored tagged files in .gitattributes are filtered OUT
3. linguist-documentation tagged files in .gitattributes are filtered OUT
4. ignore.glob default values are non-empty and include package-lock.json,
   yarn.lock, poetry.lock, go.sum
5. ignore.glob patterns are additive on top of linguist tags (NOT replacing)
6. ignore.regex overrides are additive on top of linguist tags
7. Config load with max_files=0 emits a warning
8. Config load with max_calls=0 emits a warning
9. filter_files returns (reviewable_files, skipped_files_with_reasons) tuple
"""

from __future__ import annotations

import pathlib
import sys
import warnings


# Ensure the plugin scripts directory is on sys.path so imports resolve correctly.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

# This import MUST raise ImportError until file_filter.py is implemented.
# That is the RED state.
from dso_ci_review.file_filter import (  # noqa: E402
    DEFAULT_IGNORE_GLOBS,
    filter_files,
    load_filter_config,
    parse_gitattributes_linguist_tags,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_gitattributes(tmp_path: pathlib.Path, content: str) -> pathlib.Path:
    """Write a .gitattributes file in tmp_path and return its path."""
    ga_path = tmp_path / ".gitattributes"
    ga_path.write_text(content)
    return ga_path


def _make_config(tmp_path: pathlib.Path, content: str) -> pathlib.Path:
    """Write a dso-config.conf file in tmp_path/.claude/ and return its path."""
    config_dir = tmp_path / ".claude"
    config_dir.mkdir(exist_ok=True)
    config_file = config_dir / "dso-config.conf"
    config_file.write_text(content)
    return config_file


# ---------------------------------------------------------------------------
# Scenario 1 — linguist tag filtering via .gitattributes
# ---------------------------------------------------------------------------


class TestLinguistTagFiltering:
    """Files with linguist-generated/vendored/documentation tags are filtered out."""

    def test_linguist_generated_files_are_filtered_out(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a .gitattributes file tagging foo/bar.min.js as linguist-generated
        When: filter_files is called with that file in the candidate list
        Then: foo/bar.min.js appears in skipped_files, NOT in reviewable_files

        linguist-generated marks auto-generated code (minified JS, compiled
        proto outputs, etc.) that should never be reviewed by a human or LLM.
        """
        _make_gitattributes(
            tmp_path,
            "foo/bar.min.js linguist-generated=true\n",
        )
        reviewable, skipped = filter_files(
            file_paths=["foo/bar.min.js", "src/main.py"],
            repo_root=tmp_path,
        )
        assert "foo/bar.min.js" not in reviewable, (
            "linguist-generated file must NOT appear in reviewable_files; "
            f"got reviewable={reviewable!r}"
        )
        assert "src/main.py" in reviewable, (
            f"Non-tagged file must remain in reviewable_files; got reviewable={reviewable!r}"
        )
        skipped_paths = [entry[0] for entry in skipped]
        assert "foo/bar.min.js" in skipped_paths, (
            f"linguist-generated file must appear in skipped_files_with_reasons; "
            f"got skipped={skipped!r}"
        )

    def test_linguist_generated_skip_reason_contains_tag_name(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a linguist-generated tagged file
        When: filter_files is called
        Then: the skip reason for that file mentions 'linguist-generated'
        """
        _make_gitattributes(tmp_path, "generated.pb.go linguist-generated=true\n")
        _, skipped = filter_files(
            file_paths=["generated.pb.go"],
            repo_root=tmp_path,
        )
        assert skipped, "Expected at least one skipped entry"
        reason = skipped[0][1]
        assert "linguist-generated" in reason, (
            f"Skip reason must mention 'linguist-generated'; got {reason!r}"
        )

    def test_linguist_vendored_files_are_filtered_out(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a .gitattributes file tagging vendor/lib.js as linguist-vendored
        When: filter_files is called
        Then: vendor/lib.js appears in skipped_files, NOT in reviewable_files
        """
        _make_gitattributes(tmp_path, "vendor/lib.js linguist-vendored=true\n")
        reviewable, skipped = filter_files(
            file_paths=["vendor/lib.js", "src/app.py"],
            repo_root=tmp_path,
        )
        assert "vendor/lib.js" not in reviewable, (
            f"linguist-vendored file must not be reviewable; got {reviewable!r}"
        )
        skipped_paths = [e[0] for e in skipped]
        assert "vendor/lib.js" in skipped_paths, (
            f"linguist-vendored file must be in skipped list; got {skipped!r}"
        )

    def test_linguist_documentation_files_are_filtered_out(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a .gitattributes file tagging docs/api.md as linguist-documentation
        When: filter_files is called
        Then: docs/api.md appears in skipped_files, NOT in reviewable_files
        """
        _make_gitattributes(tmp_path, "docs/api.md linguist-documentation=true\n")
        reviewable, skipped = filter_files(
            file_paths=["docs/api.md", "src/core.py"],
            repo_root=tmp_path,
        )
        assert "docs/api.md" not in reviewable, (
            f"linguist-documentation file must not be reviewable; got {reviewable!r}"
        )
        skipped_paths = [e[0] for e in skipped]
        assert "docs/api.md" in skipped_paths, (
            f"linguist-documentation file must be in skipped list; got {skipped!r}"
        )

    def test_file_with_no_linguist_tag_is_not_filtered(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a .gitattributes file with no linguist tags
        When: filter_files is called
        Then: all files appear in reviewable_files
        """
        _make_gitattributes(tmp_path, "*.sh text eol=lf\n")
        reviewable, skipped = filter_files(
            file_paths=["src/main.py", "tests/test_main.py"],
            repo_root=tmp_path,
        )
        assert "src/main.py" in reviewable, (
            f"Untagged file must be reviewable; got {reviewable!r}"
        )
        assert "tests/test_main.py" in reviewable, (
            f"Untagged file must be reviewable; got {reviewable!r}"
        )
        assert not skipped, (
            f"No files should be skipped when no linguist tags apply; got {skipped!r}"
        )

    def test_missing_gitattributes_does_not_raise(self, tmp_path: pathlib.Path) -> None:
        """Given: no .gitattributes file exists in repo_root
        When: filter_files is called
        Then: all files are returned as reviewable (graceful degradation)
        """
        reviewable, skipped = filter_files(
            file_paths=["src/main.py"],
            repo_root=tmp_path,
        )
        assert "src/main.py" in reviewable, (
            f"Without .gitattributes, file must be reviewable; got {reviewable!r}"
        )
        assert not skipped, (
            f"No files should be skipped without .gitattributes; got {skipped!r}"
        )


# ---------------------------------------------------------------------------
# Scenario 2 — parse_gitattributes_linguist_tags helper
# ---------------------------------------------------------------------------


class TestParseGitattributesLinguistTags:
    """parse_gitattributes_linguist_tags extracts tagged paths correctly."""

    def test_parses_generated_tag(self, tmp_path: pathlib.Path) -> None:
        """Given: .gitattributes with 'foo.min.js linguist-generated=true'
        When: parse_gitattributes_linguist_tags is called
        Then: returns {'foo.min.js': ['linguist-generated']}
        """
        ga_path = _make_gitattributes(tmp_path, "foo.min.js linguist-generated=true\n")
        result = parse_gitattributes_linguist_tags(ga_path)
        assert "foo.min.js" in result, (
            f"Expected 'foo.min.js' in result; got keys: {list(result.keys())!r}"
        )
        assert "linguist-generated" in result["foo.min.js"], (
            f"Expected 'linguist-generated' in tags for foo.min.js; got {result['foo.min.js']!r}"
        )

    def test_parses_multiple_tags_on_one_path(self, tmp_path: pathlib.Path) -> None:
        """Given: one path tagged with both linguist-generated and linguist-vendored
        When: parse_gitattributes_linguist_tags is called
        Then: both tags are present in the result for that path
        """
        ga_path = _make_gitattributes(
            tmp_path,
            "vendor/bundled.js linguist-generated=true linguist-vendored=true\n",
        )
        result = parse_gitattributes_linguist_tags(ga_path)
        assert "vendor/bundled.js" in result, (
            f"Expected path in result; got {list(result.keys())!r}"
        )
        tags = result["vendor/bundled.js"]
        assert "linguist-generated" in tags and "linguist-vendored" in tags, (
            f"Expected both tags; got {tags!r}"
        )

    def test_ignores_non_linguist_attributes(self, tmp_path: pathlib.Path) -> None:
        """Given: .gitattributes with only text/eol attributes
        When: parse_gitattributes_linguist_tags is called
        Then: returns empty dict (no linguist tags)
        """
        ga_path = _make_gitattributes(tmp_path, "*.sh text eol=lf\n*.py text eol=lf\n")
        result = parse_gitattributes_linguist_tags(ga_path)
        assert result == {}, (
            f"Non-linguist attributes must not appear in result; got {result!r}"
        )

    def test_handles_comment_lines(self, tmp_path: pathlib.Path) -> None:
        """Given: .gitattributes with comment lines (starting with #)
        When: parse_gitattributes_linguist_tags is called
        Then: comment lines are ignored and do not produce false-positive paths
        """
        ga_path = _make_gitattributes(
            tmp_path,
            "# This is a comment\nfoo.pb.go linguist-generated=true\n",
        )
        result = parse_gitattributes_linguist_tags(ga_path)
        assert "foo.pb.go" in result, f"Expected foo.pb.go in result; got {result!r}"
        # Comment line must not appear as a path key
        comment_keys = [k for k in result if k.startswith("#")]
        assert not comment_keys, (
            f"Comment lines must not produce path keys; got {comment_keys!r}"
        )


# ---------------------------------------------------------------------------
# Scenario 3 — ignore.glob defaults are non-empty and include lock files
# ---------------------------------------------------------------------------


class TestIgnoreGlobDefaults:
    """DEFAULT_IGNORE_GLOBS is non-empty and includes the documented lock files."""

    def test_default_ignore_globs_is_non_empty(self) -> None:
        """Given: the module-level DEFAULT_IGNORE_GLOBS constant
        When: it is inspected
        Then: it is a non-empty list/set/tuple of glob patterns

        The story requires non-empty defaults (package-lock.json etc.) so that
        operators who don't configure ignore.glob still get sensible filtering.
        """
        assert DEFAULT_IGNORE_GLOBS, (
            "DEFAULT_IGNORE_GLOBS must be non-empty; lock files should be excluded by default"
        )

    def test_default_ignore_globs_includes_package_lock(self) -> None:
        """DEFAULT_IGNORE_GLOBS must include a pattern matching **/package-lock.json."""
        patterns = list(DEFAULT_IGNORE_GLOBS)
        has_package_lock = any("package-lock.json" in p for p in patterns)
        assert has_package_lock, (
            f"DEFAULT_IGNORE_GLOBS must include a pattern matching package-lock.json; "
            f"got {patterns!r}"
        )

    def test_default_ignore_globs_includes_yarn_lock(self) -> None:
        """DEFAULT_IGNORE_GLOBS must include a pattern matching **/yarn.lock."""
        patterns = list(DEFAULT_IGNORE_GLOBS)
        has_yarn_lock = any("yarn.lock" in p for p in patterns)
        assert has_yarn_lock, (
            f"DEFAULT_IGNORE_GLOBS must include a pattern matching yarn.lock; "
            f"got {patterns!r}"
        )

    def test_default_ignore_globs_includes_poetry_lock(self) -> None:
        """DEFAULT_IGNORE_GLOBS must include a pattern matching **/poetry.lock."""
        patterns = list(DEFAULT_IGNORE_GLOBS)
        has_poetry_lock = any("poetry.lock" in p for p in patterns)
        assert has_poetry_lock, (
            f"DEFAULT_IGNORE_GLOBS must include a pattern matching poetry.lock; "
            f"got {patterns!r}"
        )

    def test_default_ignore_globs_includes_go_sum(self) -> None:
        """DEFAULT_IGNORE_GLOBS must include a pattern matching **/go.sum."""
        patterns = list(DEFAULT_IGNORE_GLOBS)
        has_go_sum = any("go.sum" in p for p in patterns)
        assert has_go_sum, (
            f"DEFAULT_IGNORE_GLOBS must include a pattern matching go.sum; "
            f"got {patterns!r}"
        )

    def test_package_lock_filtered_by_default_glob(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: package-lock.json in the file list, no custom config
        When: filter_files is called without an explicit config
        Then: package-lock.json appears in skipped_files (matched by default glob)
        """
        reviewable, skipped = filter_files(
            file_paths=["package-lock.json", "src/app.py"],
            repo_root=tmp_path,
        )
        assert "package-lock.json" not in reviewable, (
            f"package-lock.json must be filtered by default ignore.glob; "
            f"got reviewable={reviewable!r}"
        )
        skipped_paths = [e[0] for e in skipped]
        assert "package-lock.json" in skipped_paths, (
            f"package-lock.json must appear in skipped list; got skipped={skipped!r}"
        )

    def test_yarn_lock_filtered_by_default_glob(self, tmp_path: pathlib.Path) -> None:
        """Given: yarn.lock in the file list, no custom config
        When: filter_files is called
        Then: yarn.lock appears in skipped_files (matched by default glob)
        """
        reviewable, skipped = filter_files(
            file_paths=["yarn.lock", "src/app.py"],
            repo_root=tmp_path,
        )
        skipped_paths = [e[0] for e in skipped]
        assert "yarn.lock" in skipped_paths, (
            f"yarn.lock must be filtered by default glob; got skipped={skipped!r}"
        )

    def test_go_sum_filtered_by_default_glob(self, tmp_path: pathlib.Path) -> None:
        """Given: go.sum in a subdirectory, no custom config
        When: filter_files is called
        Then: subdir/go.sum appears in skipped_files (glob matches **/go.sum)
        """
        reviewable, skipped = filter_files(
            file_paths=["mymod/go.sum", "src/main.go"],
            repo_root=tmp_path,
        )
        skipped_paths = [e[0] for e in skipped]
        assert "mymod/go.sum" in skipped_paths, (
            f"mymod/go.sum must be filtered by **/go.sum glob; got skipped={skipped!r}"
        )


# ---------------------------------------------------------------------------
# Scenario 4 — ignore.glob is ADDITIVE on top of linguist tags
# ---------------------------------------------------------------------------


class TestIgnoreGlobAdditive:
    """ignore.glob patterns add to linguist tag filtering, not replace it."""

    def test_ignore_glob_and_linguist_tags_both_apply(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a linguist-generated file AND a file matching ignore.glob
        When: filter_files is called
        Then: BOTH are in skipped_files (additive, not replacing)
        """
        _make_gitattributes(tmp_path, "gen/proto.pb.go linguist-generated=true\n")
        reviewable, skipped = filter_files(
            file_paths=["gen/proto.pb.go", "package-lock.json", "src/main.py"],
            repo_root=tmp_path,
        )
        skipped_paths = [e[0] for e in skipped]
        assert "gen/proto.pb.go" in skipped_paths, (
            f"linguist-generated file must be skipped even when ignore.glob is also active; "
            f"got skipped={skipped!r}"
        )
        assert "package-lock.json" in skipped_paths, (
            f"ignore.glob-matched file must be skipped even when linguist tags are also active; "
            f"got skipped={skipped!r}"
        )
        assert "src/main.py" in reviewable, (
            f"Untagged, non-glob file must remain reviewable; got reviewable={reviewable!r}"
        )

    def test_custom_ignore_glob_adds_to_defaults(self, tmp_path: pathlib.Path) -> None:
        """Given: a custom ignore.glob pattern (*.snap) in dso-config.conf
        When: filter_files is called with a .snap file
        Then: the .snap file is filtered out AND defaults (package-lock.json) still apply

        ignore.glob is ADDITIVE — custom config appends patterns, does not replace defaults.
        """
        _make_config(
            tmp_path,
            "review.file_filter.ignore.glob=*.snap\n",
        )
        reviewable, skipped = filter_files(
            file_paths=[
                "tests/__snapshots__/foo.snap",
                "package-lock.json",
                "src/app.py",
            ],
            repo_root=tmp_path,
        )
        skipped_paths = [e[0] for e in skipped]
        assert "tests/__snapshots__/foo.snap" in skipped_paths, (
            f"Custom glob *.snap must filter snapshot files; got skipped={skipped!r}"
        )
        assert "package-lock.json" in skipped_paths, (
            f"Default globs must still apply when custom ignore.glob is set; "
            f"got skipped={skipped!r}"
        )
        assert "src/app.py" in reviewable, (
            f"Unmatched file must remain reviewable; got reviewable={reviewable!r}"
        )


# ---------------------------------------------------------------------------
# Scenario 5 — ignore.regex overrides are additive on top of linguist tags
# ---------------------------------------------------------------------------


class TestIgnoreRegexAdditive:
    """ignore.regex patterns are additive — they do not replace linguist tags."""

    def test_ignore_regex_filters_matching_files(self, tmp_path: pathlib.Path) -> None:
        """Given: a regex pattern (.*\\.generated\\.ts$) in config
        When: filter_files is called with a matching file
        Then: the file is in skipped_files with a regex-match reason
        """
        _make_config(
            tmp_path,
            "review.file_filter.ignore.regex=.*\\.generated\\.ts$\n",
        )
        reviewable, skipped = filter_files(
            file_paths=["src/api.generated.ts", "src/main.ts"],
            repo_root=tmp_path,
        )
        skipped_paths = [e[0] for e in skipped]
        assert "src/api.generated.ts" in skipped_paths, (
            f"File matching ignore.regex must be in skipped list; got skipped={skipped!r}"
        )
        assert "src/main.ts" in reviewable, (
            f"Non-matching file must remain reviewable; got reviewable={reviewable!r}"
        )

    def test_ignore_regex_and_linguist_tags_both_apply(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a linguist-generated file AND a file matching ignore.regex
        When: filter_files is called
        Then: BOTH are in skipped_files (regex is additive, not replacing linguist)
        """
        _make_gitattributes(tmp_path, "gen/proto.pb.go linguist-generated=true\n")
        _make_config(
            tmp_path,
            "review.file_filter.ignore.regex=.*\\.generated\\.ts$\n",
        )
        reviewable, skipped = filter_files(
            file_paths=["gen/proto.pb.go", "src/api.generated.ts", "src/main.py"],
            repo_root=tmp_path,
        )
        skipped_paths = [e[0] for e in skipped]
        assert "gen/proto.pb.go" in skipped_paths, (
            f"Linguist-generated file must be skipped even when ignore.regex is set; "
            f"got skipped={skipped!r}"
        )
        assert "src/api.generated.ts" in skipped_paths, (
            f"Regex-matched file must be skipped even when linguist tags are set; "
            f"got skipped={skipped!r}"
        )
        assert "src/main.py" in reviewable, (
            f"Unmatched file must remain reviewable; got reviewable={reviewable!r}"
        )

    def test_skip_reason_contains_regex_info(self, tmp_path: pathlib.Path) -> None:
        """Given: a file matching ignore.regex
        When: filter_files is called
        Then: the skip reason for that file indicates it was matched by regex
        """
        _make_config(
            tmp_path,
            "review.file_filter.ignore.regex=.*\\.lock$\n",
        )
        _, skipped = filter_files(
            file_paths=["Gemfile.lock"],
            repo_root=tmp_path,
        )
        assert skipped, "Expected at least one skipped entry"
        reason = skipped[0][1]
        assert reason, f"Skip reason must be non-empty; got {reason!r}"


# ---------------------------------------------------------------------------
# Scenario 6 — config validation: max_files=0 and max_calls=0 emit warnings
# ---------------------------------------------------------------------------


class TestConfigValidation:
    """max_files=0 and max_calls=0 emit warnings but do NOT raise exceptions."""

    def test_max_files_zero_emits_warning(self, tmp_path: pathlib.Path) -> None:
        """Given: a config file with review.file_filter.max_files=0
        When: load_filter_config is called
        Then: a UserWarning is emitted (but no exception is raised)

        max_files=0 would mean no files are ever reviewed — almost certainly
        a misconfiguration. Emit a warning so operators notice during startup.
        """
        config_file = _make_config(tmp_path, "review.file_filter.max_files=0\n")
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            load_filter_config(config_path=str(config_file))
        warning_messages = [str(w.message) for w in caught]
        has_max_files_warning = any("max_files" in msg for msg in warning_messages)
        assert has_max_files_warning, (
            f"max_files=0 must emit a warning mentioning 'max_files'; "
            f"got warnings: {warning_messages!r}"
        )

    def test_max_calls_zero_emits_warning(self, tmp_path: pathlib.Path) -> None:
        """Given: a config file with review.file_filter.max_calls=0
        When: load_filter_config is called
        Then: a UserWarning is emitted (but no exception is raised)

        max_calls=0 would prevent any LLM dispatch — almost certainly
        a misconfiguration. Emit a warning so operators notice during startup.
        """
        config_file = _make_config(tmp_path, "review.file_filter.max_calls=0\n")
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            load_filter_config(config_path=str(config_file))
        warning_messages = [str(w.message) for w in caught]
        has_max_calls_warning = any("max_calls" in msg for msg in warning_messages)
        assert has_max_calls_warning, (
            f"max_calls=0 must emit a warning mentioning 'max_calls'; "
            f"got warnings: {warning_messages!r}"
        )

    def test_nonzero_max_files_does_not_emit_warning(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a config file with review.file_filter.max_files=50 (nonzero)
        When: load_filter_config is called
        Then: no warning is emitted about max_files
        """
        config_file = _make_config(tmp_path, "review.file_filter.max_files=50\n")
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            load_filter_config(config_path=str(config_file))
        max_files_warnings = [
            str(w.message) for w in caught if "max_files" in str(w.message)
        ]
        assert not max_files_warnings, (
            f"Non-zero max_files must not emit a max_files warning; "
            f"got: {max_files_warnings!r}"
        )

    def test_nonzero_max_calls_does_not_emit_warning(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: a config file with review.file_filter.max_calls=10 (nonzero)
        When: load_filter_config is called
        Then: no warning is emitted about max_calls
        """
        config_file = _make_config(tmp_path, "review.file_filter.max_calls=10\n")
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            load_filter_config(config_path=str(config_file))
        max_calls_warnings = [
            str(w.message) for w in caught if "max_calls" in str(w.message)
        ]
        assert not max_calls_warnings, (
            f"Non-zero max_calls must not emit a max_calls warning; "
            f"got: {max_calls_warnings!r}"
        )

    def test_both_zero_both_warnings_emitted(self, tmp_path: pathlib.Path) -> None:
        """Given: both max_files=0 and max_calls=0 in config
        When: load_filter_config is called
        Then: warnings are emitted for BOTH settings
        """
        config_file = _make_config(
            tmp_path,
            "review.file_filter.max_files=0\nreview.file_filter.max_calls=0\n",
        )
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            load_filter_config(config_path=str(config_file))
        warning_messages = [str(w.message) for w in caught]
        has_max_files_warning = any("max_files" in msg for msg in warning_messages)
        has_max_calls_warning = any("max_calls" in msg for msg in warning_messages)
        assert has_max_files_warning and has_max_calls_warning, (
            f"Both max_files=0 and max_calls=0 must emit warnings; "
            f"got warnings: {warning_messages!r}"
        )

    def test_load_filter_config_does_not_raise_on_zero(
        self, tmp_path: pathlib.Path
    ) -> None:
        """Given: max_files=0 in config
        When: load_filter_config is called
        Then: no exception is raised (warning only — keep the call non-fatal)
        """
        config_file = _make_config(tmp_path, "review.file_filter.max_files=0\n")
        # Should not raise — must return a config dict/object even on zero values
        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            result = load_filter_config(config_path=str(config_file))
        assert result is not None, (
            "load_filter_config must return a non-None value even when max_files=0"
        )


# ---------------------------------------------------------------------------
# Scenario 7 — filter_files return type contract
# ---------------------------------------------------------------------------


class TestFilterFilesReturnType:
    """filter_files always returns a 2-tuple: (reviewable_files, skipped_files_with_reasons)."""

    def test_return_type_is_tuple_of_two(self, tmp_path: pathlib.Path) -> None:
        """Given: any file list
        When: filter_files is called
        Then: the return value is a 2-tuple (len == 2)
        """
        result = filter_files(file_paths=["src/main.py"], repo_root=tmp_path)
        assert isinstance(result, tuple), (
            f"filter_files must return a tuple; got {type(result).__name__}"
        )
        assert len(result) == 2, (
            f"filter_files must return a 2-tuple; got length {len(result)}"
        )

    def test_reviewable_files_is_list(self, tmp_path: pathlib.Path) -> None:
        """Given: any file list
        When: filter_files is called
        Then: the first element is a list of file paths (strings)
        """
        reviewable, _ = filter_files(file_paths=["src/main.py"], repo_root=tmp_path)
        assert isinstance(reviewable, list), (
            f"reviewable_files must be a list; got {type(reviewable).__name__}"
        )

    def test_skipped_files_is_list_of_tuples(self, tmp_path: pathlib.Path) -> None:
        """Given: a file that matches an ignore glob
        When: filter_files is called
        Then: skipped_files_with_reasons is a list of (path, reason) tuples
        """
        _, skipped = filter_files(
            file_paths=["package-lock.json"],
            repo_root=tmp_path,
        )
        assert isinstance(skipped, list), (
            f"skipped_files_with_reasons must be a list; got {type(skipped).__name__}"
        )
        if skipped:
            entry = skipped[0]
            assert isinstance(entry, (tuple, list)) and len(entry) == 2, (
                f"Each skipped entry must be a (path, reason) 2-tuple; got {entry!r}"
            )
            assert isinstance(entry[0], str), (
                f"Skipped path must be a string; got {type(entry[0]).__name__}: {entry[0]!r}"
            )
            assert isinstance(entry[1], str), (
                f"Skip reason must be a string; got {type(entry[1]).__name__}: {entry[1]!r}"
            )

    def test_empty_file_list_returns_empty_lists(self, tmp_path: pathlib.Path) -> None:
        """Given: an empty file list
        When: filter_files is called
        Then: returns ([], [])
        """
        reviewable, skipped = filter_files(file_paths=[], repo_root=tmp_path)
        assert reviewable == [], f"Expected empty reviewable list; got {reviewable!r}"
        assert skipped == [], f"Expected empty skipped list; got {skipped!r}"
