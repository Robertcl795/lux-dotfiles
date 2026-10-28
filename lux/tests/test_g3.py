import hashlib
import importlib.util
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
module = importlib.util.spec_from_file_location("documents", ROOT / "lib/documents.py")
docs = importlib.util.module_from_spec(module)
module.loader.exec_module(docs)

POLICY = """inbox/** human preserve-before-delete
designs/** human
specs/** shared gates-human-only
sources/** agent append-only
TODAY.md shared
reminders/** cli
system/** agent approval-required
.lux/** agent approval-required
CHANGES.md agent append-only
INDEX.md agent
INSTRUCTIONS.md agent approval-required
.gitignore agent
knowledge/** agent
"""
SPEC = """# {{title}}
Purpose: proposal.
## 6. Phases
- G1: Design
- G2: Implementation
## Gates

"""
TODAY = """# Today
Current planning date: 2026-10-27.
## Focus
Ship G3
## Accepted Tasks
- [ ] T001: One
- [x] T002: Two
## Proposed Tasks
- P1: Proposal
"""


class G3(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.vault = self.home / "vault with spaces"
        self.vault.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), LUX_VAULT=str(self.vault),
                        XDG_CONFIG_HOME=str(self.home / ".config"),
                        XDG_STATE_HOME=str(self.home / ".state"), LUX_DESKTOP="off", LUX_MOBILE="off")
        for key in ["LUX_MODE", "LUX_WORK_ROOT", "GIT_INDEX_FILE"]:
            self.env.pop(key, None)
        self.files = {
            ".lux/ownership": POLICY, ".lux/sources.sha256": "", "INDEX.md": "# Index\n",
            "TODAY.md": TODAY, "CHANGES.md": "# Changes\n", "INSTRUCTIONS.md": "# Rules\n",
            "system/templates/spec.md": SPEC, "reminders/REMINDERS.md": "# Reminders\n",
            "knowledge/lesson.md": "# Lesson\n",
            ".gitignore": "ignored/\n",
        }
        for name in self.files:
            if name.endswith(".md") and name != "INDEX.md" and not name.startswith("system/templates/"):
                self.files["INDEX.md"] += f"- [{name}]({name})\n"
        for group in ["inbox/", "designs/", "resources/", "system/templates/", ".github/"]:
            self.files["INDEX.md"] += f"- [{group}]({group})\n"
            self.write(group + ".gitkeep", "")
        self.files[".lux/ownership"] += "resources/** agent\n.github/** agent\n"
        for name, value in self.files.items():
            self.write(name, value)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Reviewed adoption baseline")

    def write(self, name, data):
        path = self.vault / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)

    def git(self, *args, ok=True):
        result = subprocess.run(["git", "-C", str(self.vault), *args], env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def cli(self, *args, ok=True):
        result = subprocess.run(["bash", str(ROOT / "bin/lux"), *args], cwd=self.home, env=self.env,
                                capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def changed(self, path="knowledge/lesson.md", value="# New lesson\n"):
        self.write(path, value)
        with (self.vault / "CHANGES.md").open("a") as out:
            out.write("\n## Updated fixture\n\nChanged with approval.\n")
        self.git("add", ".")

    def message(self, actor="agent", extra=""):
        path = self.home / "message"
        path.write_text(f"Fixture\n\nLux-Actor: {actor}\n{extra}")
        return str(path)

    def checked(self, actor="agent", extra="", ok=True):
        return self.cli("check", "--staged", "--message", self.message(actor, extra), ok=ok)

    def test_full_worktree_check(self):
        self.cli("check")

    def test_broken_link_and_anchor_fail(self):
        with (self.vault / "knowledge/lesson.md").open("a") as out:
            out.write("[bad](missing.md)\n")
        self.assertNotEqual(self.cli("check", ok=False).returncode, 0)
        self.write("knowledge/lesson.md", "# Lesson\n[bad](#missing)\n")
        self.assertNotEqual(self.cli("check", ok=False).returncode, 0)
        self.write("knowledge/lesson.md", "# Lesson\n[good](#lesson)\n")
        self.cli("check")

    def test_fenced_examples_are_not_links(self):
        self.write("knowledge/lesson.md", "# Lesson\n```md\n[bad](missing.md)\n```\n")
        self.cli("check")

    def test_links_with_spaces(self):
        self.write("knowledge/lesson.md", "# Lesson\n[space](<../vault note.md#note>)\n")
        self.write("vault note.md", "# Note\n")
        with (self.vault / ".lux/ownership").open("a") as out:
            out.write("vault* agent\n")
        with (self.vault / "INDEX.md").open("a") as out:
            out.write("- [vault note.md](<vault note.md>)\n")
        # Angle-bracket destinations count as a file entry too.
        self.cli("check")

    def test_unknown_path_fails(self):
        self.write("unknown", "bad")
        self.assertIn("unowned", self.cli("check", ok=False).stderr)

    def test_unsupported_markdown_reported(self):
        self.write("knowledge/lesson.md", "# Lesson\n[x][ref]\n[ref]: target\n")
        self.assertIn("reference-style", self.cli("check", ok=False).stderr)

    def test_invalid_date_and_duplicate_tasks(self):
        self.write("TODAY.md", TODAY.replace("2026-10-27", "2026-02-30"))
        self.assertNotEqual(self.cli("today", ok=False).returncode, 0)
        self.write("TODAY.md", TODAY.replace("T002", "T001"))
        self.assertNotEqual(self.cli("checkout", "--done", "T001", ok=False).returncode, 0)

    def test_checkout_updates_only_accepted_and_preserves_source(self):
        self.cli("checkout", "--done", "T001,T002", "--comment", "Done\nwith detail")
        self.assertIn("- [x] T001: One", (self.vault / "TODAY.md").read_text())
        self.assertIn("- P1: Proposal", (self.vault / "TODAY.md").read_text())
        source = next((self.vault / "sources").glob("*.md"))
        self.assertIn("Done\nwith detail", source.read_text())
        self.cli("check")
        self.git("add", ".")
        self.checked("cli", "Lux-Operation: checkout\n")

    def test_checkout_unknown_reopen_duplicate_do_not_write(self):
        for done in ["T001", "P1,T002", "T002,T002"]:
            before = docs.snapshot(self.vault)
            self.assertNotEqual(self.cli("checkout", "--done", done, ok=False).returncode, 0)
            self.assertEqual(before, docs.snapshot(self.vault))

    def test_spec_creation_and_no_overwrite(self):
        self.cli("spec", "new", "my-spec")
        self.assertIn("- G1: Design", (self.vault / "specs/my-spec.md").read_text())
        self.cli("check")
        self.git("add", ".")
        self.checked("cli", "Lux-Operation: spec-new\n")
        self.assertNotEqual(self.cli("spec", "new", "my-spec", ok=False).returncode, 0)
        self.assertNotEqual(self.cli("spec", "new", "../bad", ok=False).returncode, 0)

    def test_gate_requires_terminal(self):
        self.cli("spec", "new", "sample")
        before = docs.snapshot(self.vault)
        self.assertNotEqual(self.cli("gate", "approve", "sample", "G1", ok=False).returncode, 0)
        self.assertEqual(before, docs.snapshot(self.vault))

    def terminal(self, gate, response):
        master, slave = pty.openpty()
        process = subprocess.Popen(["bash", str(ROOT / "bin/lux"), "gate", "approve", "sample", gate],
                                   stdin=slave, stdout=slave, stderr=slave, env=self.env, cwd=self.home)
        os.close(slave)
        self.addCleanup(os.close, master)
        output = b""
        while process.poll() is None:
            if select.select([master], [], [], 5)[0]:
                try:
                    part = os.read(master, 8192)
                except OSError:
                    break
                output += part
                if b"Type exactly" in output:
                    os.write(master, (response + "\n").encode())
                    break
        try:
            return process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            self.fail("gate interaction hung")

    def test_gate_cancel_order_and_two_approvals(self):
        self.cli("spec", "new", "sample")
        self.git("add", ".")
        self.git("commit", "-qm", "Spec\n\nLux-Actor: cli\nLux-Operation: spec-new")
        before = docs.snapshot(self.vault)
        self.assertEqual(self.terminal("G1", "no"), 130)
        self.assertEqual(before, docs.snapshot(self.vault))
        self.assertNotEqual(self.terminal("G2", "approve G2"), 0)
        self.assertEqual(self.terminal("G1", "approve G1"), 0)
        self.git("add", ".")
        self.checked("cli", "Lux-Operation: gate-approve\n")
        self.git("commit", "-qm", "Gate\n\nLux-Actor: cli\nLux-Operation: gate-approve")
        self.assertNotEqual(self.terminal("G1", "approve G1"), 0)
        self.assertEqual(self.terminal("G2", "approve G2"), 0)
        self.git("add", ".")
        self.checked("cli", "Lux-Operation: gate-approve\n")

    def test_staged_not_worktree(self):
        self.changed()
        self.write("knowledge/lesson.md", "# Bad\n[x](absent.md)\n")
        self.checked()
        self.git("add", "knowledge/lesson.md")
        self.write("knowledge/lesson.md", "# Repaired only in working tree\n")
        self.assertNotEqual(self.checked(ok=False).returncode, 0)

    def test_human_override_audited(self):
        self.changed()
        self.assertNotEqual(self.checked("human", ok=False).returncode, 0)
        self.assertNotEqual(self.checked("human", "Lux-Override: repair note\n", ok=False).returncode, 0)
        with (self.vault / "CHANGES.md").open("a") as out:
            out.write("\nHuman exception: repair note\n")
        self.git("add", "CHANGES.md")
        self.checked("human", "Lux-Override: repair note\n")

    def test_override_does_not_rewrite_log(self):
        self.changed("CHANGES.md", "# Rewritten repair note\n")
        self.assertNotEqual(self.checked("human", "Lux-Override: repair note\n", ok=False).returncode, 0)

    def test_rehashed_source_still_immutable(self):
        self.write("sources/original.md", "original\n")
        with (self.vault / "INDEX.md").open("a") as out:
            out.write("- [sources/original.md](sources/original.md)\n")
        digest = hashlib.sha256(b"original\n").hexdigest()
        self.write(".lux/sources.sha256", f"{digest}  sources/original.md\n")
        self.changed()
        self.git("commit", "-qm", "Source\n\nLux-Actor: agent")
        self.write("sources/original.md", "rewritten\n")
        rewritten_hash = hashlib.sha256(b"rewritten\n").hexdigest()
        self.write(".lux/sources.sha256", f"{rewritten_hash}  sources/original.md\n")
        self.changed()
        docs.validate(docs.snapshot(self.vault, ":"), self.vault)
        self.assertNotEqual(self.checked(ok=False).returncode, 0)

    def test_policy_self_authorization_fails(self):
        self.write(".lux/ownership", self.files[".lux/ownership"].replace("knowledge/** agent", "knowledge/** human"))
        self.changed()
        self.assertNotEqual(self.checked("human", ok=False).returncode, 0)
        self.checked("agent", "Lux-Approval: fixture approval\n")

    def test_inbox_delete_requires_exact_preservation(self):
        self.write("inbox/raw.md", "verbatim\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Human inbox baseline")
        (self.vault / "inbox/raw.md").unlink()
        self.changed()
        self.assertNotEqual(self.checked("agent", ok=False).returncode, 0)

    def test_cli_cannot_edit_memory(self):
        self.changed()
        self.assertNotEqual(self.checked("cli", "Lux-Operation: checkout\n", ok=False).returncode, 0)

    def test_actor_and_approval_trailers(self):
        self.changed("INSTRUCTIONS.md", "# Rules updated\n")
        self.assertNotEqual(self.checked(ok=False).returncode, 0)
        self.checked(extra="Lux-Approval: user request\n")
        self.assertNotEqual(self.checked(extra="Lux-Actor: human\n", ok=False).returncode, 0)

    def test_hooks_install_conflicts_and_validation(self):
        self.cli("hooks", "install")
        self.cli("hooks", "install")
        self.changed()
        self.assertNotEqual(self.git("commit", "-qm", "No actor", ok=False).returncode, 0)
        self.cli("commit", "--actor", "agent", "-m", "Validated")
        message = self.git("show", "-s", "--format=%B").stdout
        self.assertIn("Co-authored-by: Copilot", message)
        self.assertIn("Lux-Actor: agent", message)
        self.git("config", "core.hooksPath", "custom")
        self.assertNotEqual(self.cli("hooks", "install", ok=False).returncode, 0)

    def test_hooks_do_not_overwrite_existing(self):
        hook = self.vault / ".git/hooks/pre-commit"
        hook.write_text("# existing\n")
        self.assertNotEqual(self.cli("hooks", "install", ok=False).returncode, 0)
        self.assertEqual(hook.read_text(), "# existing\n")

    def test_commit_leaves_unstaged_untouched(self):
        self.changed()
        self.write("knowledge/lesson.md", "# Unstaged\n")
        self.cli("commit", "--actor", "agent", "-m", "Only staged")
        self.assertEqual(self.git("show", "HEAD:knowledge/lesson.md").stdout, "# New lesson\n")
        self.assertEqual((self.vault / "knowledge/lesson.md").read_text(), "# Unstaged\n")

    def test_range_validates_each_commit(self):
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.changed()
        self.git("commit", "-qm", "Agent\n\nLux-Actor: agent")
        self.cli("check", "--range", f"{base}..HEAD")
        self.changed(value="# Human wrong\n")
        self.git("commit", "-qm", "Human\n\nLux-Actor: human")
        self.assertNotEqual(self.cli("check", "--range", f"{base}..HEAD", ok=False).returncode, 0)

    def test_snapshot_external_links_report_partial_coverage(self):
        self.changed(value="# Lesson\n[external](../../not-present/README.md)\n")
        result = self.checked()
        self.assertIn("unverifiable", result.stderr)
        self.assertNotEqual(self.cli("check", ok=False).returncode, 0)

    def test_index_missing_entry_fails(self):
        self.write("INDEX.md", self.files["INDEX.md"].replace("- [TODAY.md](TODAY.md)\n", ""))
        self.assertNotEqual(self.cli("check", ok=False).returncode, 0)

    def test_triage_exact_source_allows_agent_deletion(self):
        self.write("inbox/raw.md", "literal text\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Inbox baseline")
        (self.vault / "inbox/raw.md").unlink()
        self.write("sources/raw.md", "literal text\n")
        self.write(".lux/sources.sha256", f"{hashlib.sha256(b'literal text' + bytes([10])).hexdigest()}  sources/raw.md\n")
        with (self.vault / "INDEX.md").open("a") as out:
            out.write("- [sources/raw.md](sources/raw.md)\n")
        self.changed()
        self.checked()

    def test_override_does_not_change_gate_records(self):
        self.cli("spec", "new", "sample")
        self.git("add", ".")
        self.git("commit", "-qm", "Spec baseline")
        path = self.vault / "specs/sample.md"
        path.write_text(path.read_text() + "- G1: approved yesterday\n")
        self.changed()
        self.assertNotEqual(self.checked("human", "Lux-Override: Changed with approval.\n", ok=False).returncode, 0)

    def test_cli_gate_cannot_rewrite_design(self):
        self.cli("spec", "new", "sample")
        self.git("add", ".")
        self.git("commit", "-qm", "Spec baseline")
        self.assertEqual(self.terminal("G1", "approve G1"), 0)
        path = self.vault / "specs/sample.md"
        path.write_text(path.read_text().replace("Purpose: proposal.", "Purpose: covert rewrite."))
        self.git("add", ".")
        self.assertIn("design", self.checked("cli", "Lux-Operation: gate-approve\n", ok=False).stderr)

    def test_invalid_reminder_in_index_is_not_hidden_by_worktree_repair(self):
        self.changed("reminders/REMINDERS.md", "# Reminders\n- [ ] R000001 2026-02-30T09:00Z bad\n")
        self.write("reminders/REMINDERS.md", "# Reminders\n")
        self.assertNotEqual(self.checked("cli", "Lux-Operation: remind-add\n", ok=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
