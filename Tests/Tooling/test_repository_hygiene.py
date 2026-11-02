import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
REQUIRED = ["LICENSE", "README.md", "AGENTS.md", "SECURITY.md", "docs/PROVENANCE.md"]
# Assembled so the literals do not trip the ratchet on this file.
BUNDLE_PREFIX = "app." + "portavoz"
TOOLKIT = "Cloud" + "Kit"
# The owner's global hooks must not judge fixture commits.
ISOLATED_GIT = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}


class HygieneFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.git("init", "-q", "-b", "main", "--template=")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        (root / "scripts").mkdir()
        shutil.copy(REPO / "scripts/check-repository-hygiene.sh", root / "scripts")
        shutil.copy(REPO / ".gitignore", root)
        for name in REQUIRED:
            self.write(name, "x\n")
        (root / "CLAUDE.md").symlink_to("AGENTS.md")

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, env=ISOLATED_GIT)

    def write(self, name: str, content: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self, message: str = "chore: fixture") -> None:
        self.git("add", "-A", "-f")
        self.git("commit", "-q", "-m", message)

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "scripts/check-repository-hygiene.sh"],
            cwd=self.root,
            capture_output=True,
            text=True,
            env=ISOLATED_GIT,
        )


class RepositoryHygieneTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.fixture = HygieneFixture(Path(temp.name))

    def assert_rejected(self, expected: str) -> None:
        result = self.fixture.run()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(expected, result.stderr)

    def test_clean_repository_passes(self) -> None:
        self.fixture.commit()
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_passes_before_the_first_commit(self) -> None:
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_required_file(self) -> None:
        (self.fixture.root / "LICENSE").unlink()
        self.assert_rejected("Required file is missing")

    def test_rejects_claude_md_that_is_not_a_symlink(self) -> None:
        (self.fixture.root / "CLAUDE.md").unlink()
        self.fixture.write("CLAUDE.md", "copy\n")
        self.assert_rejected("must be a symlink")

    def test_rejects_tracked_planning_file(self) -> None:
        self.fixture.write("planning_secret.md", "x\n")
        self.fixture.commit()
        self.assert_rejected("must not be tracked")

    def test_rejects_conflict_markers(self) -> None:
        self.fixture.write("a.txt", "<" * 7 + " HEAD\n")
        self.assert_rejected("merge-conflict markers")

    def test_rejects_ticket_reference(self) -> None:
        self.fixture.write("a.txt", "see " + "APUN" + "-12\n")
        self.assert_rejected("Private ticket references")

    def test_rejects_source_app_identifiers(self) -> None:
        for token in [
            BUNDLE_PREFIX + ".mac",
            "PORTAVOZ" + "_UI_TEST_DEFAULTS",
            "PV" + "Design",
            '"PV' + 'OZ"',
            "0x5056" + "_4F5A",
            "Apun" + "tador",
            TOOLKIT,
            "Application Support/" + "Portavoz",
        ]:
            with self.subTest(token=token):
                self.fixture.write("Sources/a.swift", f"let x = {token}\n")
                self.assert_rejected("Source-app identifiers")

    def test_allows_source_app_identifiers_in_provenance(self) -> None:
        self.fixture.write("docs/PROVENANCE.md", f"{BUNDLE_PREFIX} {TOOLKIT}\n")
        self.fixture.commit()
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_word_portavoz_alone_is_allowed(self) -> None:
        self.fixture.write("docs/DECISIONS.md", "Portavoz D516\n")
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_private_local_paths(self) -> None:
        self.fixture.write("a.txt", "/Users/" + "someone/file\n")
        self.assert_rejected("Private local paths")

    def test_rejects_gpl_markers(self) -> None:
        self.fixture.write("a.swift", "// SPDX-License-Identifier: " + "GPL-3.0\n")
        self.assert_rejected("GPL license markers")

    def test_rejects_ai_attribution_in_commit_messages(self) -> None:
        for message in [
            "feat: x\n\nCo-Authored-By: " + "Claude <noreply@anthropic.com>",
            "feat: x\n\nGenerated with " + "Claude Code",
        ]:
            with self.subTest(message=message):
                self.fixture.commit(message)
                self.assert_rejected("AI attribution")
                self.fixture.git("update-ref", "-d", "HEAD")

    def test_accepts_human_co_author(self) -> None:
        self.fixture.commit("feat: x\n\nCo-Authored-By: Ada <ada@example.com>")
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_mutable_action(self) -> None:
        self.fixture.write(".github/workflows/ci.yml", "steps:\n  - uses: actions/checkout@v7\n")
        self.assert_rejected("full-length commit SHAs")

    def test_accepts_pinned_action(self) -> None:
        sha = "a" * 40
        self.fixture.write(".github/workflows/ci.yml", f"steps:\n  - uses: actions/checkout@{sha} # v7\n")
        result = self.fixture.run()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_oversized_test_file(self) -> None:
        self.fixture.write("Tests/Big.swift", "// x\n" * 2401)
        self.assert_rejected("under 2400 lines")

    def test_rejects_ignore_rule_regression(self) -> None:
        gitignore = self.fixture.root / ".gitignore"
        gitignore.write_text(gitignore.read_text().replace("/planning_*.md\n", ""))
        self.assert_rejected("not ignored")


if __name__ == "__main__":
    unittest.main()
