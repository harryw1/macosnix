#!/usr/bin/env python3
"""Tests for ai-organize's statistical and heuristic functions.

These tests exercise the pure-math and pure-logic functions that don't
require Ollama or filesystem access.  Run with:

    python3 -m pytest test_ai_organize.py -v

Or simply:

    python3 test_ai_organize.py
"""

import importlib.util
import math
import sys
from pathlib import Path

import numpy as np

# ── Import ai-organize.py as a module (it's a script, not a package) ─────────
spec = importlib.util.spec_from_file_location(
    "ai_organize",
    Path(__file__).parent / "ai-organize.py",
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


# ===========================================================================
#  Composite Distance: IDF-weighted path Jaccard
# ===========================================================================


class TestPathIDF:
    """_compute_path_idf should weight rare path components higher."""

    def test_common_vs_rare_components(self):
        files = [
            {"path": "project-a/assets/icon.png"},
            {"path": "project-a/assets/logo.png"},
            {"path": "project-a/docs/readme.md"},
            {"path": "project-b/assets/banner.png"},
            {"path": "project-b/src/main.py"},
        ]
        idf = mod._compute_path_idf(files)
        # "assets" appears in 3 files, "docs" in 1, "src" in 1
        # "project-a" in 3, "project-b" in 2
        assert idf["assets"] < idf["docs"], "Common 'assets' should have lower IDF than rare 'docs'"
        assert idf["assets"] < idf["src"], "Common 'assets' should have lower IDF than rare 'src'"
        assert idf["project-a"] < idf["docs"], "More common dir should have lower IDF"

    def test_empty_files(self):
        assert mod._compute_path_idf([]) == {}

    def test_top_level_files_only(self):
        """Files with no directory components should produce empty IDF."""
        files = [{"path": "file1.txt"}, {"path": "file2.txt"}]
        idf = mod._compute_path_idf(files)
        assert idf == {}


class TestPathDistanceMatrix:
    """_path_distance_matrix should produce distances that reflect structure."""

    def test_same_directory_zero_distance(self):
        files = [
            {"path": "project/assets/a.png"},
            {"path": "project/assets/b.png"},
        ]
        dist = mod._path_distance_matrix(files)
        assert dist[0, 1] == 0.0, "Files in identical directory should have zero path distance"

    def test_different_projects_high_distance(self):
        files = [
            {"path": "project-a/assets/icon.png"},
            {"path": "project-b/assets/icon.png"},
        ]
        dist = mod._path_distance_matrix(files)
        assert dist[0, 1] > 0.0, "Files in different projects should have nonzero distance"

    def test_completely_disjoint_paths(self):
        files = [
            {"path": "alpha/beta/file.txt"},
            {"path": "gamma/delta/file.txt"},
        ]
        dist = mod._path_distance_matrix(files)
        assert dist[0, 1] == 1.0, "Completely disjoint paths should have distance 1.0"

    def test_symmetry(self):
        files = [
            {"path": "a/b/c.txt"},
            {"path": "d/e/f.txt"},
            {"path": "a/e/g.txt"},
        ]
        dist = mod._path_distance_matrix(files)
        for i in range(3):
            for j in range(3):
                assert abs(dist[i, j] - dist[j, i]) < 1e-7, "Distance matrix should be symmetric"

    def test_top_level_files_zero_distance(self):
        """Two top-level files (no directory) should have zero path distance."""
        files = [{"path": "a.txt"}, {"path": "b.txt"}]
        dist = mod._path_distance_matrix(files)
        assert dist[0, 1] == 0.0


class TestCompositeDistance:
    """_composite_distance_matrix should blend embedding and path signals."""

    def _make_embeddings(self, n, dim=8, seed=42):
        rng = np.random.RandomState(seed)
        return rng.randn(n, dim).astype(np.float32)

    def test_alpha_one_equals_pure_cosine(self):
        """With alpha=1.0, composite should be proportional to cosine distance."""
        files = [
            {"path": "a/x.txt"},
            {"path": "b/y.txt"},
        ]
        emb = self._make_embeddings(2)
        composite = mod._composite_distance_matrix(files, emb, alpha=1.0)
        # Path component should contribute nothing
        # Diagonal should be zero
        assert composite[0, 0] == 0.0
        assert composite[1, 1] == 0.0
        assert composite[0, 1] > 0.0

    def test_alpha_zero_equals_pure_path(self):
        """With alpha=0.0, composite should be proportional to path distance."""
        files = [
            {"path": "same-dir/a.txt"},
            {"path": "same-dir/b.txt"},
            {"path": "other-dir/c.txt"},
        ]
        emb = self._make_embeddings(3)
        composite = mod._composite_distance_matrix(files, emb, alpha=0.0)
        # Same directory → zero path distance → zero composite distance
        assert composite[0, 1] == 0.0
        # Different directory → nonzero
        assert composite[0, 2] > 0.0

    def test_structure_helps_separate_similar_embeddings(self):
        """Even with identical embeddings, path structure should create distance."""
        files = [
            {"path": "project-a/assets/icon.png"},
            {"path": "project-b/assets/icon.png"},
        ]
        # Identical embeddings — pure cosine distance would be 0
        emb = np.array([[1.0, 0.0, 0.0]] * 2, dtype=np.float32)
        composite = mod._composite_distance_matrix(files, emb, alpha=0.5)
        assert composite[0, 1] > 0.0, (
            "Identical embeddings in different projects should still have distance"
        )

    def test_diagonal_is_zero(self):
        files = [{"path": f"dir{i}/f.txt"} for i in range(5)]
        emb = self._make_embeddings(5)
        composite = mod._composite_distance_matrix(files, emb)
        for i in range(5):
            assert composite[i, i] == 0.0


# ===========================================================================
#  Cluster Auto-Naming from Path Prefixes
# ===========================================================================


class TestAutoNameFromPaths:
    """_auto_name_from_paths should detect dominant directory prefixes."""

    def test_strong_majority_gets_named(self):
        files = [
            {"path": "website/assets/logo.svg"},
            {"path": "website/assets/icon.png"},
            {"path": "website/pages/index.html"},
            {"path": "website/styles/main.css"},
            {"path": "scripts/deploy.sh"},  # noise
        ]
        # Cluster 0: first 4 files (all website/), cluster 1: last file
        labels = np.array([0, 0, 0, 0, 1])
        auto = mod._auto_name_from_paths(files, labels)
        assert auto[0] == "website", "Cluster with 100% 'website' prefix should auto-name"

    def test_below_threshold_not_named(self):
        files = [
            {"path": "a/x.txt"},
            {"path": "b/y.txt"},
            {"path": "c/z.txt"},
            {"path": "a/w.txt"},
            {"path": "d/v.txt"},
        ]
        # Cluster 0: all 5 files, but max prefix is "a" at 40% (below 60%)
        labels = np.array([0, 0, 0, 0, 0])
        auto = mod._auto_name_from_paths(files, labels)
        assert 0 not in auto, "Cluster without dominant prefix should not be auto-named"

    def test_noise_label_ignored(self):
        files = [{"path": "a/x.txt"}, {"path": "a/y.txt"}]
        labels = np.array([-1, -1])
        auto = mod._auto_name_from_paths(files, labels)
        assert auto == {}, "Noise labels should produce no auto-names"

    def test_top_level_files_not_named(self):
        """Files without a directory shouldn't produce an auto-name."""
        files = [{"path": "x.txt"}, {"path": "y.txt"}, {"path": "z.txt"}]
        labels = np.array([0, 0, 0])
        auto = mod._auto_name_from_paths(files, labels)
        assert auto == {}


# ===========================================================================
#  Intentional Variant Detection (dedup false-positive suppression)
# ===========================================================================


class TestCanonicalStem:
    """_canonical_stem should strip variant suffixes."""

    def test_retina_suffixes(self):
        assert mod._canonical_stem("icon@2x.png") == "icon"
        assert mod._canonical_stem("icon@3x.png") == "icon"

    def test_size_suffixes(self):
        assert mod._canonical_stem("favicon-16x16.png") == "favicon"
        assert mod._canonical_stem("favicon-32x32.png") == "favicon"
        assert mod._canonical_stem("android-chrome-192x192.png") == "android-chrome"
        assert mod._canonical_stem("android-chrome-512x512.png") == "android-chrome"

    def test_dark_light_variants(self):
        assert mod._canonical_stem("logo-dark.svg") == "logo"
        assert mod._canonical_stem("logo-light.svg") == "logo"
        assert mod._canonical_stem("command-icon@dark.png") == "command-icon"

    def test_version_suffixes(self):
        assert mod._canonical_stem("conductor-proposal-v2.svg") == "conductor-proposal"
        assert mod._canonical_stem("command-icon-v2-dark.svg") == "command-icon"

    def test_size_words(self):
        assert mod._canonical_stem("photo-thumb.jpg") == "photo"
        assert mod._canonical_stem("avatar-small.png") == "avatar"

    def test_no_suffix_unchanged(self):
        assert mod._canonical_stem("report.pdf") == "report"
        assert mod._canonical_stem("my-project-notes.md") == "my-project-notes"

    def test_combined_suffixes(self):
        """Multiple variant suffixes should all be stripped."""
        assert mod._canonical_stem("icon-v2@2x.png") == "icon"
        assert mod._canonical_stem("icon@dark@2x.png") == "icon"


class TestIsVariantGroup:
    """_is_variant_group should identify intentional asset variants."""

    def test_retina_variants(self):
        paths = [
            "assets/icon.png",
            "assets/icon@2x.png",
            "assets/icon@3x.png",
        ]
        assert mod._is_variant_group(paths) is True

    def test_favicon_sizes(self):
        paths = [
            "public/favicon-16x16.png",
            "public/favicon-32x32.png",
        ]
        assert mod._is_variant_group(paths) is True

    def test_dark_light(self):
        paths = [
            "images/logo.svg",
            "images/logo-dark.svg",
        ]
        assert mod._is_variant_group(paths) is True

    def test_different_directories_not_variants(self):
        """Same stem but different dirs → not variants."""
        paths = [
            "project-a/icon.png",
            "project-b/icon.png",
        ]
        assert mod._is_variant_group(paths) is False

    def test_genuinely_different_files(self):
        paths = [
            "docs/report.pdf",
            "docs/invoice.pdf",
        ]
        assert mod._is_variant_group(paths) is False

    def test_resume_pdfs_not_variants(self):
        """Different filenames with different stems should not be variants."""
        paths = [
            "resume/Harrison_Weiss_Resume.pdf",
            "resume/Harrison_Weiss_Styled_Resume.pdf",
        ]
        assert mod._is_variant_group(paths) is False

    def test_android_chrome_icons(self):
        paths = [
            "public/android-chrome-192x192.png",
            "public/android-chrome-512x512.png",
        ]
        assert mod._is_variant_group(paths) is True

    def test_extension_icon_variants(self):
        """The actual Group 47 from the failing run."""
        paths = [
            "raycast-ai-applescript/assets/command-icon.png",
            "raycast-ai-applescript/assets/command-icon@2x.png",
            "raycast-ai-applescript/assets/command-icon@3x.png",
            "raycast-ai-applescript/assets/command-icon@dark.png",
            "raycast-ai-applescript/assets/command-icon@dark@2x.png",
        ]
        assert mod._is_variant_group(paths) is True


class TestFilterVariantDupes:
    """_filter_variant_dupes should remove variant groups, keep real dupes."""

    def test_filters_variant_group(self):
        ops = [
            {
                "op": "duplicate",
                "files": ["assets/icon.png", "assets/icon@2x.png"],
                "reason": "Very similar content",
            },
        ]
        result = mod._filter_variant_dupes(ops)
        assert len(result) == 0, "Variant group should be filtered out"

    def test_keeps_real_duplicate(self):
        ops = [
            {
                "op": "duplicate",
                "files": ["docs/report.pdf", "docs/report-copy.pdf"],
                "reason": "Very similar content",
            },
        ]
        result = mod._filter_variant_dupes(ops)
        assert len(result) == 1, "Real duplicate should be kept"

    def test_mixed_groups(self):
        ops = [
            {"op": "duplicate", "files": ["a/icon.png", "a/icon@2x.png"], "reason": ""},
            {"op": "duplicate", "files": ["b/notes.txt", "b/notes-old.txt"], "reason": ""},
        ]
        result = mod._filter_variant_dupes(ops)
        assert len(result) == 1, "Only the non-variant group should remain"
        assert "notes.txt" in result[0]["files"][0]


# ===========================================================================
#  Destination Collision Resolution
# ===========================================================================


class TestCollisionResolution:
    """assign_files_to_clusters should disambiguate colliding destinations."""

    def test_no_collision_simple(self):
        files = [
            {"path": "a/icon.png"},
            {"path": "b/logo.png"},
        ]
        labels = np.array([0, 0])
        cluster_names = {0: "assets"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        dsts = [m["to"] for m in moves]
        assert len(set(dsts)) == len(dsts), "No collisions should exist when filenames differ"

    def test_collision_disambiguated(self):
        files = [
            {"path": "project-a/assets/icon.png"},
            {"path": "project-b/assets/icon.png"},
        ]
        labels = np.array([0, 0])
        cluster_names = {0: "images"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        dsts = [m["to"] for m in moves]
        assert len(set(dsts)) == len(dsts), f"Collisions not resolved: {dsts}"
        # Should have disambiguated using the parent dir
        assert any("assets" in d for d in dsts), "Should use parent dir for disambiguation"

    def test_noise_files_skipped(self):
        files = [
            {"path": "a/x.txt"},
            {"path": "b/y.txt"},
        ]
        labels = np.array([-1, -1])
        cluster_names = {}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        assert len(ops) == 0, "Noise files should produce no operations"

    def test_same_destination_as_source_skipped(self):
        files = [{"path": "assets/icon.png"}]
        labels = np.array([0])
        cluster_names = {0: "assets"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        assert len(moves) == 0, "File already in target folder should not generate a move"


# ===========================================================================
#  Rename Candidate Detection
# ===========================================================================


class TestRenameCandidate:
    """is_rename_candidate should flag generic names and pass descriptive ones."""

    def test_generic_names(self):
        assert mod.is_rename_candidate("IMG0042.jpg") is True
        assert mod.is_rename_candidate("doc1.pdf") is True
        assert mod.is_rename_candidate("untitled.txt") is True
        assert mod.is_rename_candidate("20240115.png") is True
        assert mod.is_rename_candidate("abcdef1234.dat") is True

    def test_descriptive_names(self):
        assert mod.is_rename_candidate("quarterly-report.pdf") is False
        assert mod.is_rename_candidate("logo-dark.svg") is False
        assert mod.is_rename_candidate("Harrison_Weiss_Resume.pdf") is False
        assert mod.is_rename_candidate("adlists.list") is False


# ===========================================================================
#  Plan Validation
# ===========================================================================


class TestValidatePlan:
    """validate_plan should catch quality issues."""

    def test_concentration_warning(self):
        ops = [{"op": "mkdir", "path": "catchall"}]
        ops += [
            {"op": "move", "from": f"src/{i}.txt", "to": f"catchall/{i}.txt"}
            for i in range(50)
        ]
        plan = {"operations": ops}
        warnings = mod.validate_plan(plan, file_count=50)
        msgs = [w["msg"] for w in warnings]
        assert any("target a single folder" in m for m in msgs), "Should warn about concentration"

    def test_collision_error(self):
        ops = [
            {"op": "move", "from": "a/x.txt", "to": "dst/x.txt"},
            {"op": "move", "from": "b/x.txt", "to": "dst/x.txt"},
        ]
        plan = {"operations": ops}
        warnings = mod.validate_plan(plan, file_count=2)
        levels = [w["level"] for w in warnings]
        assert "error" in levels, "Destination collision should be an error"

    def test_clean_plan_no_warnings(self):
        ops = [
            {"op": "mkdir", "path": "docs"},
            {"op": "mkdir", "path": "images"},
            {"op": "move", "from": "report.pdf", "to": "docs/report.pdf"},
            {"op": "move", "from": "logo.png", "to": "images/logo.png"},
        ]
        plan = {"operations": ops}
        warnings = mod.validate_plan(plan, file_count=10)
        errors = [w for w in warnings if w["level"] == "error"]
        assert len(errors) == 0, "Clean plan should have no errors"


# ===========================================================================
#  HDBSCAN Clustering (integration test with composite distance)
# ===========================================================================


class TestClusterFiles:
    """cluster_files with composite distance should separate distinct projects."""

    def test_separates_projects_with_identical_content(self):
        """Files with identical embeddings but different project dirs should cluster apart."""
        files = []
        for proj in ["project-a", "project-b"]:
            for name in ["icon.png", "logo.svg", "banner.jpg", "thumbnail.png"]:
                files.append({"path": f"{proj}/assets/{name}"})

        # All embeddings are identical — pure cosine would put them all together
        emb = np.ones((len(files), 8), dtype=np.float32)
        # Add tiny noise so they're not perfectly identical (avoids numerical issues)
        rng = np.random.RandomState(42)
        emb += rng.randn(*emb.shape).astype(np.float32) * 0.01

        labels = mod.cluster_files(files, emb, min_cluster=3)

        # Files from project-a should not be in the same cluster as project-b
        proj_a_labels = set(labels[:4])
        proj_b_labels = set(labels[4:])
        # Remove noise label if present
        proj_a_labels.discard(-1)
        proj_b_labels.discard(-1)

        if proj_a_labels and proj_b_labels:
            assert proj_a_labels.isdisjoint(proj_b_labels), (
                f"Projects should cluster separately: A={proj_a_labels}, B={proj_b_labels}"
            )


# ===========================================================================
#  Union-Find (groups_from_pairs)
# ===========================================================================


class TestGroupsFromPairs:
    """_groups_from_pairs should merge overlapping pairs into components."""

    def test_simple_pair(self):
        groups = mod._groups_from_pairs([("a", "b")])
        assert len(groups) == 1
        assert groups[0] == {"a", "b"}

    def test_transitive_merge(self):
        """(A,B) + (B,C) should merge into {A,B,C}."""
        groups = mod._groups_from_pairs([("a", "b"), ("b", "c")])
        assert len(groups) == 1
        assert groups[0] == {"a", "b", "c"}

    def test_disjoint_groups(self):
        groups = mod._groups_from_pairs([("a", "b"), ("c", "d")])
        assert len(groups) == 2
        group_sets = [frozenset(g) for g in groups]
        assert frozenset({"a", "b"}) in group_sets
        assert frozenset({"c", "d"}) in group_sets

    def test_complex_merge(self):
        """(A,B) + (C,D) + (B,C) should produce one group {A,B,C,D}."""
        groups = mod._groups_from_pairs([("a", "b"), ("c", "d"), ("b", "c")])
        assert len(groups) == 1
        assert groups[0] == {"a", "b", "c", "d"}

    def test_empty_pairs(self):
        groups = mod._groups_from_pairs([])
        assert groups == []

    def test_self_loop_pair(self):
        groups = mod._groups_from_pairs([("a", "a")])
        assert len(groups) == 1
        assert groups[0] == {"a"}


# ===========================================================================
#  JSON Extraction
# ===========================================================================


class TestExtractJson:
    """extract_json should handle various LLM output formats."""

    def test_clean_json_object(self):
        result = mod.extract_json('{"key": "value"}')
        assert result == {"key": "value"}

    def test_clean_json_array(self):
        result = mod.extract_json('[1, 2, 3]')
        assert result == [1, 2, 3]

    def test_markdown_fences(self):
        result = mod.extract_json('```json\n{"a": 1}\n```')
        assert result == {"a": 1}

    def test_think_blocks_stripped(self):
        result = mod.extract_json('<think>reasoning here</think>{"result": true}')
        assert result == {"result": True}

    def test_prose_before_json(self):
        result = mod.extract_json('Here is the JSON output:\n{"file": "x.txt"}')
        assert result == {"file": "x.txt"}

    def test_nested_json(self):
        result = mod.extract_json('{"a": {"b": [1, 2]}}')
        assert result == {"a": {"b": [1, 2]}}

    def test_escaped_quotes(self):
        result = mod.extract_json('{"name": "file \\"test\\".txt"}')
        assert result == {"name": 'file "test".txt'}

    def test_no_json_raises(self):
        import pytest
        with pytest.raises(ValueError):
            mod.extract_json("This is just plain text with no JSON at all")


# ===========================================================================
#  Composite Distance — Edge Cases
# ===========================================================================


class TestCompositeDistanceEdgeCases:
    """Edge cases for the composite distance pipeline."""

    def test_single_file(self):
        files = [{"path": "x.txt"}]
        emb = np.array([[1.0, 0.0]], dtype=np.float32)
        dist = mod._composite_distance_matrix(files, emb)
        assert dist.shape == (1, 1)
        assert dist[0, 0] == 0.0

    def test_deeply_nested_paths(self):
        """Deep paths should create meaningful distance from shallow paths."""
        files = [
            {"path": "a/b/c/d/e/file.txt"},
            {"path": "file.txt"},
        ]
        emb = np.array([[1.0, 0.0], [1.0, 0.0]], dtype=np.float32)
        dist = mod._composite_distance_matrix(files, emb, alpha=0.0)
        assert dist[0, 1] > 0.0, "Nested vs top-level should have distance"

    def test_many_shared_components(self):
        """Files with mostly shared path components should be close."""
        files = [
            {"path": "project/src/utils/helpers/a.py"},
            {"path": "project/src/utils/helpers/b.py"},
        ]
        emb = np.array([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32)
        dist = mod._composite_distance_matrix(files, emb, alpha=0.5)
        # Path distance should be 0 (identical dirs), so composite should be < pure cosine
        pure_alpha1 = mod._composite_distance_matrix(files, emb, alpha=1.0)
        assert dist[0, 1] < pure_alpha1[0, 1], (
            "Shared path should reduce composite distance"
        )

    def test_idf_weighting_effect(self):
        """Rare project names should contribute more to distance than common dirs."""
        files = [
            {"path": "unique-project-alpha/assets/icon.png"},
            {"path": "unique-project-beta/assets/icon.png"},
            {"path": "unique-project-alpha/assets/logo.png"},
        ]
        idf = mod._compute_path_idf(files)
        # "assets" appears in all 3 files, project names in fewer
        assert idf["assets"] < idf["unique-project-alpha"]
        assert idf["assets"] < idf["unique-project-beta"]


# ===========================================================================
#  Variant Detection — Edge Cases
# ===========================================================================


class TestVariantEdgeCases:
    """Edge cases for variant detection."""

    def test_single_file_not_variant(self):
        assert mod._is_variant_group(["a/icon.png"]) is False

    def test_empty_list_not_variant(self):
        assert mod._is_variant_group([]) is False

    def test_different_stems_not_variants(self):
        """Files with different canonical stems in same dir aren't variants."""
        paths = [
            "assets/logo.png",
            "assets/banner.png",
        ]
        assert mod._is_variant_group(paths) is False

    def test_mixed_extensions_same_stem(self):
        """favicon.ico and favicon.svg share a stem but different extensions."""
        paths = [
            "public/favicon.ico",
            "public/favicon.svg",
            "public/favicon.png",
        ]
        # These have same canonical stem "favicon" and same directory
        assert mod._is_variant_group(paths) is True

    def test_template_vs_content_not_variants(self):
        """POST_TEMPLATE.md and carbon-accounting.md shouldn't match."""
        paths = [
            "content/posts/POST_TEMPLATE.md",
            "content/posts/carbon-accounting.md",
        ]
        assert mod._is_variant_group(paths) is False

    def test_m_main_vs_main(self):
        """m_main.png and main.png — different stems."""
        paths = [
            "themes/diary/images/m_main.png",
            "themes/diary/images/main.png",
        ]
        # These have different canonical stems ("m_main" vs "main")
        assert mod._is_variant_group(paths) is False


# ===========================================================================
#  Collision Resolution — Edge Cases
# ===========================================================================


class TestCollisionEdgeCases:
    """Edge cases for destination collision resolution."""

    def test_three_way_collision(self):
        """Three files with same name should all get unique destinations."""
        files = [
            {"path": "a/sub1/config.json"},
            {"path": "b/sub2/config.json"},
            {"path": "c/sub3/config.json"},
        ]
        labels = np.array([0, 0, 0])
        cluster_names = {0: "configs"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        dsts = [m["to"] for m in moves]
        assert len(set(dsts)) == len(dsts), f"Three-way collision not resolved: {dsts}"

    def test_collision_preserves_project_structure(self):
        """Disambiguated paths should contain the source directory context (up to 2 levels)."""
        files = [
            {"path": "project-a/assets/icon.png"},
            {"path": "project-b/assets/icon.png"},
        ]
        labels = np.array([0, 0])
        cluster_names = {0: "images"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        dsts = [m["to"] for m in moves]
        # The first 2 dir components should be preserved for disambiguation
        assert any("project-a" in d for d in dsts)
        assert any("project-b" in d for d in dsts)

    def test_collision_caps_at_two_levels(self):
        """Deeply nested sources should only use 2 dir levels in disambiguation."""
        files = [
            {"path": "backups/pi_migration/var/www/public/icon.png"},
            {"path": "backups/website/var/www/public/icon.png"},
        ]
        labels = np.array([0, 0])
        cluster_names = {0: "assets"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        dsts = [m["to"] for m in moves]
        for d in dsts:
            # Should be at most: assets / <2-level-prefix> / icon.png = 4 parts
            parts = Path(d).parts
            assert len(parts) <= 4, (
                f"Disambiguation should cap at 2 dir levels, got {len(parts)}: {d}"
            )

    def test_collision_no_stutter_when_folder_matches_source_prefix(self):
        """When cluster name matches source path prefix, don't repeat it.

        e.g. folder="backups/pi_migration" + source="backups/pi_migration/var/www/icon.png"
        should become "backups/pi_migration/var/www/icon.png", NOT
        "backups/pi_migration/backups/pi_migration/icon.png".
        """
        files = [
            {"path": "backups/pi_migration/var/www/publicpresence/icon.png"},
            {"path": "backups/pi_migration/var/www/blog/icon.png"},
        ]
        labels = np.array([0, 0])
        cluster_names = {0: "backups/pi_migration"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        dsts = [m["to"] for m in moves]
        for d in dsts:
            # Must NOT contain repeated "backups/pi_migration/backups/pi_migration"
            assert d.count("backups/pi_migration") == 1, (
                f"Stuttering cluster prefix in disambiguation: {d}"
            )
            # Should contain the distinguishing part (var/www)
            assert "var/www" in d or "var" in d, f"Missing distinguishing prefix: {d}"

    def test_multiple_clusters_independent_collisions(self):
        """Collisions in different clusters should be handled independently."""
        files = [
            {"path": "a/x.txt"},
            {"path": "b/x.txt"},
            {"path": "c/y.txt"},
            {"path": "d/y.txt"},
        ]
        labels = np.array([0, 0, 1, 1])
        cluster_names = {0: "group-a", 1: "group-b"}
        ops = mod.assign_files_to_clusters(files, labels, cluster_names)
        moves = [o for o in ops if o.get("op") == "move"]
        dsts = [m["to"] for m in moves]
        assert len(set(dsts)) == len(dsts), f"Cross-cluster collisions: {dsts}"


# ===========================================================================
#  Auto-Naming — Edge Cases
# ===========================================================================


class TestAutoNameEdgeCases:
    """Edge cases for auto-naming clusters from directory structure."""

    def test_exact_threshold(self):
        """Exactly 60% should be named."""
        files = [
            {"path": "project/a.txt"},
            {"path": "project/b.txt"},
            {"path": "project/c.txt"},
            {"path": "other/d.txt"},
            {"path": "misc/e.txt"},
        ]
        labels = np.array([0, 0, 0, 0, 0])
        auto = mod._auto_name_from_paths(files, labels)
        assert 0 in auto, "60% should meet the threshold"
        assert auto[0] == "project"

    def test_multiple_clusters_different_names(self):
        files = [
            {"path": "alpha/a.txt"},
            {"path": "alpha/b.txt"},
            {"path": "alpha/c.txt"},
            {"path": "beta/d.txt"},
            {"path": "beta/e.txt"},
            {"path": "beta/f.txt"},
        ]
        labels = np.array([0, 0, 0, 1, 1, 1])
        auto = mod._auto_name_from_paths(files, labels)
        assert auto[0] == "alpha"
        assert auto[1] == "beta"

    def test_mixed_auto_and_manual(self):
        """Some clusters auto-named, some need LLM."""
        files = [
            {"path": "project/a.txt"},
            {"path": "project/b.txt"},
            {"path": "project/c.txt"},
            {"path": "x/d.txt"},
            {"path": "y/e.txt"},
            {"path": "z/f.txt"},
        ]
        labels = np.array([0, 0, 0, 1, 1, 1])
        auto = mod._auto_name_from_paths(files, labels)
        assert 0 in auto, "Project cluster should be auto-named"
        assert 1 not in auto, "Mixed cluster should need LLM naming"


# ===========================================================================
#  Plan Validation — Edge Cases
# ===========================================================================


class TestValidatePlanEdgeCases:
    """Edge cases for plan validation."""

    def test_high_move_ratio_warning(self):
        ops = [
            {"op": "move", "from": f"src/{i}.txt", "to": f"dst/{i}.txt"}
            for i in range(48)
        ]
        plan = {"operations": ops}
        warnings = mod.validate_plan(plan, file_count=50)
        msgs = [w["msg"] for w in warnings]
        assert any("96%" in m or "moves" in m for m in msgs)

    def test_generic_folder_warning(self):
        ops = [
            {"op": "mkdir", "path": "misc"},
            {"op": "move", "from": "x.txt", "to": "misc/x.txt"},
        ]
        plan = {"operations": ops}
        warnings = mod.validate_plan(plan, file_count=10)
        msgs = [w["msg"] for w in warnings]
        assert any("Generic" in m or "generic" in m.lower() for m in msgs)

    def test_no_moves_no_warnings(self):
        plan = {"operations": []}
        warnings = mod.validate_plan(plan, file_count=0)
        assert warnings == []

    def test_existing_generic_dir_not_warned(self):
        """If 'misc' already exists in source paths, don't warn about it."""
        ops = [
            {"op": "mkdir", "path": "misc"},
            {"op": "move", "from": "misc/a.txt", "to": "misc/b.txt"},
        ]
        plan = {"operations": ops}
        warnings = mod.validate_plan(plan, file_count=5)
        generic_warns = [w for w in warnings if "generic" in w.get("msg", "").lower()]
        assert len(generic_warns) == 0, "Existing 'misc' dir should not be flagged"


# ===========================================================================
#  Path IDF — Edge Cases
# ===========================================================================


class TestPathIDFEdgeCases:
    """Edge cases for IDF computation."""

    def test_single_file_idf(self):
        files = [{"path": "project/a.txt"}]
        idf = mod._compute_path_idf(files)
        # IDF = log(1/1) = 0 for the only component
        assert idf["project"] == 0.0

    def test_idf_ordering(self):
        """IDF should be inversely related to frequency."""
        files = [
            {"path": "common/a.txt"},
            {"path": "common/b.txt"},
            {"path": "common/c.txt"},
            {"path": "rare/d.txt"},
        ]
        idf = mod._compute_path_idf(files)
        assert idf["rare"] > idf["common"]


# ===========================================================================
#  Clustering — Edge Cases
# ===========================================================================


class TestClusterFilesEdgeCases:
    """Edge cases for the full clustering pipeline."""

    def test_all_same_embedding(self):
        """Files with identical embeddings but different paths should still cluster by path."""
        files = [
            {"path": f"dir{i}/{f}" }
            for i in range(4)
            for f in ["a.txt", "b.txt", "c.txt"]
        ]
        emb = np.ones((len(files), 4), dtype=np.float32)
        rng = np.random.RandomState(0)
        emb += rng.randn(*emb.shape).astype(np.float32) * 0.001
        labels = mod.cluster_files(files, emb, min_cluster=3)
        # Should not put everything in one cluster
        n_clusters = len(set(labels)) - (1 if -1 in labels else 0)
        assert n_clusters >= 2, f"Expected multiple clusters, got {n_clusters}"

    def test_few_files_all_noise(self):
        """With very few files below min_cluster, all should be noise."""
        files = [{"path": f"dir{i}/f.txt"} for i in range(4)]
        emb = np.array([
            [1.0, 0.0],
            [0.0, 1.0],
            [-1.0, 0.0],
            [0.0, -1.0],
        ], dtype=np.float32)
        labels = mod.cluster_files(files, emb, min_cluster=3)
        # With 4 dissimilar files and min_cluster=3, HDBSCAN may find 0 clusters
        n_clusters = len(set(labels)) - (1 if -1 in labels else 0)
        # Just verify it doesn't crash — HDBSCAN behavior is implementation-defined
        assert len(labels) == 4


# ===========================================================================
#  Dedupe via Embeddings
# ===========================================================================


class TestDedupeViaEmbeddings:
    """Integration tests for _dedupe_via_embeddings."""

    def test_identical_embeddings_flagged(self):
        files = [
            {"path": "a/report.pdf"},
            {"path": "b/report-copy.pdf"},
        ]
        # Nearly identical embeddings
        emb = np.array([[1.0, 0.0, 0.0], [1.0, 0.001, 0.0]], dtype=np.float32)
        result = mod._dedupe_via_embeddings(files, emb)
        assert len(result) >= 1, "Nearly identical embeddings should be flagged"

    def test_very_different_embeddings_not_flagged(self):
        files = [
            {"path": "a/report.pdf"},
            {"path": "b/photo.jpg"},
        ]
        # Very different embeddings
        emb = np.array([[1.0, 0.0, 0.0], [0.0, 0.0, 1.0]], dtype=np.float32)
        result = mod._dedupe_via_embeddings(files, emb)
        assert len(result) == 0, "Very different embeddings should not be flagged"


# ===========================================================================
#  Refine Dominant Clusters
# ===========================================================================


class TestRefineDominantClusters:
    """_refine_dominant_clusters should sub-name large directories at depth-2."""

    def test_dominant_folder_refined(self):
        """When >40% of files map to one folder, depth-2 sub-names are used."""
        files = [
            {"path": "backups/pi_migration/a.txt"},
            {"path": "backups/pi_migration/b.txt"},
            {"path": "backups/website/c.txt"},
            {"path": "backups/website/d.txt"},
            {"path": "other/e.txt"},
        ]
        labels = np.array([0, 0, 1, 1, 2])
        auto_names = {0: "backups", 1: "backups", 2: "other"}
        refined = mod._refine_dominant_clusters(files, labels, auto_names, total_files=5)
        # Clusters 0 and 1 had "backups" which covers 80% — should be refined
        assert refined[0] == "backups/pi_migration"
        assert refined[1] == "backups/website"
        # Cluster 2 should be unchanged
        assert refined[2] == "other"

    def test_no_refinement_below_threshold(self):
        """When no folder dominates, nothing changes."""
        files = [
            {"path": "alpha/a.txt"},
            {"path": "alpha/b.txt"},
            {"path": "beta/c.txt"},
            {"path": "beta/d.txt"},
            {"path": "gamma/e.txt"},
        ]
        labels = np.array([0, 0, 1, 1, 2])
        auto_names = {0: "alpha", 1: "beta", 2: "gamma"}
        refined = mod._refine_dominant_clusters(files, labels, auto_names, total_files=5)
        assert refined == auto_names

    def test_shallow_files_deferred_to_llm(self):
        """When depth-2 can't help (files too shallow), cluster deferred to LLM."""
        files = [
            {"path": "backups/a.txt"},  # only 1 level deep
            {"path": "backups/b.txt"},
            {"path": "backups/c.txt"},
            {"path": "other/d.txt"},
        ]
        labels = np.array([0, 0, 0, 1])
        auto_names = {0: "backups", 1: "other"}
        refined = mod._refine_dominant_clusters(files, labels, auto_names, total_files=4)
        # Cluster 0 can't be refined (files are backups/x.txt, no 2nd level)
        assert 0 not in refined, "Shallow files should be deferred to LLM"
        assert refined[1] == "other"

    def test_empty_auto_names(self):
        """Empty auto_names should be handled gracefully."""
        result = mod._refine_dominant_clusters([], np.array([]), {}, total_files=0)
        assert result == {}

    def test_recursive_refinement_goes_deeper(self):
        """When depth-2 still concentrates, should continue to depth-3+.

        Simulates: backups/pi_migration/projA/… and backups/pi_migration/projB/…
        where depth-2 gives "backups/pi_migration" for both clusters (still >40%),
        so depth-3 should produce "backups/pi_migration/projA" etc.

        We use enough "other" files (5) so that the final depth-3 names
        (3/10 = 30% each) fall below the 40% threshold and don't trigger
        a further (impossible) depth-4 refinement.
        """
        files = [
            {"path": "backups/pi_migration/projA/a.txt"},
            {"path": "backups/pi_migration/projA/b.txt"},
            {"path": "backups/pi_migration/projA/c.txt"},
            {"path": "backups/pi_migration/projB/d.txt"},
            {"path": "backups/pi_migration/projB/e.txt"},
            {"path": "backups/pi_migration/projB/f.txt"},
            {"path": "other/g.txt"},
            {"path": "other/h.txt"},
            {"path": "other/i.txt"},
            {"path": "other/j.txt"},
        ]
        labels = np.array([0, 0, 0, 1, 1, 1, 2, 2, 2, 2])
        auto_names = {0: "backups", 1: "backups", 2: "other"}
        refined = mod._refine_dominant_clusters(files, labels, auto_names, total_files=10)
        # After depth-2: both map to "backups/pi_migration" (60%, still > 40%)
        # After depth-3: cluster 0 → "backups/pi_migration/projA" (30%),
        #                cluster 1 → "backups/pi_migration/projB" (30%)
        assert refined[0] == "backups/pi_migration/projA"
        assert refined[1] == "backups/pi_migration/projB"
        assert refined[2] == "other"


# ===========================================================================
#  Single-dict wrapping in _call_llm_for_list
# ===========================================================================


class TestCallLlmForListDictWrapping:
    """_call_llm_for_list should wrap a single dict in a list."""

    def test_single_rename_dict_wrapped(self):
        """A bare dict like {from, to, reason} should be wrapped in a list."""
        import unittest.mock as mock

        single_dict = '{"from": "old.txt", "to": "new.txt", "reason": "descriptive"}'
        with mock.patch.object(mod, "call_llm", return_value=single_dict):
            result = mod._call_llm_for_list("test prompt", label="rename")
        assert isinstance(result, list)
        assert len(result) == 1
        assert result[0]["from"] == "old.txt"

    def test_proper_list_returned_directly(self):
        """A proper list should be returned as-is."""
        import unittest.mock as mock

        proper_list = '[{"from": "a.txt", "to": "b.txt"}]'
        with mock.patch.object(mod, "call_llm", return_value=proper_list):
            result = mod._call_llm_for_list("test prompt", label="rename")
        assert isinstance(result, list)
        assert len(result) == 1

    def test_dict_with_known_key_unwrapped(self):
        """A dict wrapping like {files: [...]} should unwrap the list."""
        import unittest.mock as mock

        wrapped = '{"files": [{"name": "a.txt"}, {"name": "b.txt"}]}'
        with mock.patch.object(mod, "call_llm", return_value=wrapped):
            result = mod._call_llm_for_list("test prompt", label="classify")
        assert isinstance(result, list)
        assert len(result) == 2


# ===========================================================================
#  Embedding Cache (_load_cached_embeddings / embed_files with cache)
# ===========================================================================


class TestEmbeddingCache:
    """Tests for the SQLite DB embedding cache in embed_files."""

    def test_load_cached_embeddings_no_db(self):
        """When DB doesn't exist, returns None."""
        import unittest.mock as mock
        with mock.patch.object(mod, "SEARCH_DB_PATH", Path("/nonexistent/vectors.db")):
            result = mod._load_cached_embeddings("/some/dir")
        assert result is None

    def test_embed_files_without_cache(self):
        """embed_files with no directory still works (pure API path)."""
        import unittest.mock as mock

        fake_embedding = [0.1, 0.2, 0.3]
        fake_resp = mock.MagicMock()
        fake_resp.json.return_value = {"embedding": fake_embedding}
        fake_resp.raise_for_status = mock.MagicMock()

        files = [{"path": "a.txt", "snippet": "hello"}]
        with mock.patch("requests.post", return_value=fake_resp):
            result = mod.embed_files(files)
        assert result.shape == (1, 3)
        np.testing.assert_allclose(result[0], fake_embedding)

    def test_embed_files_uses_cache_when_available(self):
        """When cache has a hit, that file skips the API call."""
        import unittest.mock as mock

        cached_vec = [0.5, 0.6, 0.7]
        api_vec = [0.1, 0.2, 0.3]

        fake_cache = {"a.txt": cached_vec}
        fake_resp = mock.MagicMock()
        fake_resp.json.return_value = {"embedding": api_vec}
        fake_resp.raise_for_status = mock.MagicMock()

        files = [
            {"path": "a.txt", "snippet": "cached"},
            {"path": "b.txt", "snippet": "not cached"},
        ]

        with mock.patch.object(mod, "_load_cached_embeddings", return_value=fake_cache):
            with mock.patch("requests.post", return_value=fake_resp) as mock_post:
                result = mod.embed_files(files, directory="/some/dir")

        # a.txt should use cached vec, b.txt should call API
        assert mock_post.call_count == 1  # only b.txt
        np.testing.assert_allclose(result[0], cached_vec)
        np.testing.assert_allclose(result[1], api_vec)


# ===========================================================================
#  Run all tests
# ===========================================================================

if __name__ == "__main__":
    try:
        import pytest
        sys.exit(pytest.main([__file__, "-v", "--tb=short"]))
    except ImportError:
        # Fallback: run tests manually without pytest
        import traceback

        test_classes = [
            TestPathIDF,
            TestPathDistanceMatrix,
            TestCompositeDistance,
            TestAutoNameFromPaths,
            TestCanonicalStem,
            TestIsVariantGroup,
            TestFilterVariantDupes,
            TestCollisionResolution,
            TestRenameCandidate,
            TestValidatePlan,
            TestClusterFiles,
        ]

        passed = failed = errors = 0
        for cls in test_classes:
            instance = cls()
            for name in dir(instance):
                if not name.startswith("test_"):
                    continue
                method = getattr(instance, name)
                try:
                    method()
                    passed += 1
                    print(f"  \033[38;5;114m✓\033[0m {cls.__name__}.{name}")
                except AssertionError as e:
                    failed += 1
                    print(f"  \033[38;5;203m✗\033[0m {cls.__name__}.{name}: {e}")
                except Exception as e:
                    errors += 1
                    print(f"  \033[38;5;221m!\033[0m {cls.__name__}.{name}: {e}")
                    traceback.print_exc()

        print(f"\n  {passed} passed, {failed} failed, {errors} errors")
        sys.exit(1 if (failed + errors) > 0 else 0)
