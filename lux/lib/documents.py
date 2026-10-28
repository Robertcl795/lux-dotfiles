"""Standard-library document and Git snapshot support for the Bash CLI."""

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def text(files, name):
    require(name in files, f"missing {name}")
    try:
        return files[name].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Invalid(f"not UTF-8: {name}") from exc


def snapshot(root, ref=None):
    files = {}
    if ref is None:
        tracked = None
        if (root / ".git").exists():
            tracked = {os.fsdecode(p) for p in git(root, "ls-files", "-co", "--exclude-standard", "-z").split(b"\0") if p}
        for folder, dirs, names in os.walk(root, followlinks=False):
            dirs[:] = [d for d in dirs if d != ".git"]
            for name in dirs + names:
                path = Path(folder) / name
                require(not path.is_symlink(), f"symlink in vault: {path.relative_to(root)}")
            for name in names:
                path = Path(folder) / name
                relative = path.relative_to(root).as_posix()
                if tracked is None or relative in tracked:
                    files[relative] = path.read_bytes()
        return files
    command = ("ls-files", "--stage", "-z") if ref == ":" else ("ls-tree", "-rz", ref)
    for record in git(root, *command).split(b"\0"):
        if not record:
            continue
        meta, name = record.split(b"\t", 1)
        parts = meta.decode().split()
        mode, oid = (parts[0], parts[1]) if ref == ":" else (parts[0], parts[2])
        require(mode in ("100644", "100755"), f"unsupported Git file mode: {name!r}")
        if ref == ":":
            require(parts[2] == "0", "unmerged Git index")
        files[os.fsdecode(name)] = git(root, "cat-file", "blob", oid)
    return files


def section(document, heading):
    matches = list(re.finditer(rf"^{re.escape(heading)}\s*$", document, re.M))
    require(len(matches) == 1, f"expected exactly one {heading} heading")
    start = matches[0].end()
    end = re.search(r"^## ", document[start:], re.M)
    return document[start:start + end.start()] if end else document[start:]


def tasks(document):
    date = re.search(r"^Current planning date: (\d{4}-\d{2}-\d{2})\.", document, re.M)
    require(date is not None, "missing TODAY planning date")
    dt.date.fromisoformat(date[1])
    section(document, "## Focus")
    accepted = section(document, "## Accepted Tasks")
    found = re.findall(r"^- \[([ x])\] (T\d+): (.+)$", accepted, re.M)
    require(len({t[1] for t in found}) == len(found), "duplicate accepted task IDs")
    require(not re.search(r"^- \[.*\].*$", re.sub(r"^- \[[ x]\] T\d+: .+$", "", accepted, flags=re.M), re.M),
            "malformed accepted task")
    return found


def unfenced(document):
    lines, fence = [], None
    for line in document.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            if fence is None:
                fence = marker[1][0]
            elif marker[1][0] == fence:
                fence = None
            lines.append("")
        else:
            lines.append("" if fence else re.sub(r"`[^`]*`", "", line))
    return "\n".join(lines)


def anchors(document):
    result, counts = set(), {}
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*#*\s*$", unfenced(document), re.M):
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        result.add(f"{slug}-{count}" if count else slug)
    return result


def policy(files):
    result = []
    for line in text(files, ".lux/ownership").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split()
        require(2 <= len(parts) <= 3 and parts[1] in {"human", "shared", "agent", "cli"}, "invalid ownership row")
        require(len(parts) == 2 or parts[2] in {
            "append-only", "preserve-before-delete", "gates-human-only", "approval-required"
        }, "invalid ownership rule")
        result.append(parts)
    require(result, "empty ownership manifest")
    return result


def ownership(rules, path):
    for row in rules:
        if fnmatch.fnmatchcase(path, row[0]):
            return row[1], row[2] if len(row) == 3 else ""
    raise Invalid(f"unowned path: {path}")


def validate(files, root, local=False):
    rules = policy(files)
    for path in files:
        ownership(rules, path)
    tasks(text(files, "TODAY.md"))
    index = text(files, "INDEX.md")
    groups = ("inbox/", "designs/", "resources/", "system/templates/", ".github/")
    for group in groups:
        require(f"]({group})" in index, f"missing index group: {group}")
    exempt = {"INDEX.md", "AGENTS.md", "CLAUDE.md", "GEMINI.md"}
    for path in files:
        if path.endswith(".md") and path not in exempt and not path.startswith(
            ("inbox/", "designs/", "system/templates/", ".github/")
        ):
            entries = re.findall(r"^- \[[^\]\n]+\]\((?:<([^>]+)>|([^)]+))\):?.*$", index, re.M)
            require(sum(1 for angle, bare in entries if (angle or bare) == path) == 1,
                    f"expected one index entry: {path}")
    hashes = {}
    for line in text(files, ".lux/sources.sha256").splitlines():
        match = re.fullmatch(r"([a-f0-9]{64})  (sources/[^\r\n]+)", line)
        require(match is not None, "invalid source manifest row")
        digest, path = match.groups()
        require(path not in hashes and path in files, f"duplicate or missing source: {path}")
        require(hashlib.sha256(files[path]).hexdigest() == digest, f"source fingerprint mismatch: {path}")
        hashes[path] = digest
    require(set(hashes) == {p for p in files if p.startswith("sources/")}, "unregistered source")
    seen_reminders = set()
    for line in text(files, "reminders/REMINDERS.md").splitlines():
        if not line.startswith("- ["):
            continue
        match = re.fullmatch(r"- \[[ x-]\] (R\d{6}) (\S+) (.+)", line)
        require(match is not None, "malformed reminder record")
        identity, stamp, _ = match.groups()
        require(identity not in seen_reminders, "duplicate reminder ID")
        require(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?(?:Z|[+-]\d\d:\d\d)", stamp),
                "reminder needs explicit timezone")
        dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        seen_reminders.add(identity)
    external = set()
    link_pattern = re.compile(r"!?\[[^\]\n]*\]\((<[^>\n]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)")
    for path in files:
        if not path.endswith(".md") or path.startswith("inbox/"):
            continue
        document = unfenced(text(files, path))
        require(not re.search(r"^\s*\[[^]]+\]:|\[[^]\n]+\]\[[^]\n]*\]", document, re.M),
                f"reference-style Markdown links need explicit validation: {path}")
        matches = list(link_pattern.finditer(document))
        residue = link_pattern.sub("", document)
        require("](" not in residue, f"unsupported Markdown link syntax: {path}")
        for match in matches:
            target = unquote(match[1].strip("<>"))
            url = urlsplit(target)
            if url.scheme:
                continue
            dest = os.path.normpath(str(PurePosixPath(path).parent / url.path)) if url.path else path
            if dest.startswith("../") or dest.startswith("/"):
                if local:
                    require((root / dest).exists(), f"broken external local link: {path}: {target}")
                external.add(dest)
                continue
            exists = dest in files or any(p.startswith(dest.rstrip("/") + "/") for p in files)
            if not exists and local:
                exists = (root / dest).is_dir()
            require(exists, f"broken local link: {path}: {target}")
            if url.fragment:
                require(dest in files and url.fragment in anchors(text(files, dest)),
                        f"missing anchor: {path}: {target}")
    for path in files:
        if path.endswith(".json"):
            json.loads(text(files, path))
    if external:
        print(f"Coverage: {len(external)} external repository links "
              + ("checked locally" if local else "unverifiable in Git snapshots"), file=sys.stderr)


def gates(data):
    return section(data.decode(), "## Gates") if re.search(rb"^## Gates\s*$", data, re.M) else ""


def trailers(message):
    parsed = {}
    for key, value in re.findall(r"^(Lux-[A-Za-z]+): (.+)$", message, re.M):
        require(key not in parsed, f"duplicate trailer: {key}")
        parsed[key] = value
    return parsed


def transition(before, after, message=None):
    require(".lux/ownership" in before, "no policy baseline; create an explicitly reviewed adoption checkpoint first")
    rules = policy(before)
    changed = {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}
    for path in changed:
        old, new = before.get(path), after.get(path)
        if path.startswith("sources/") and old is not None:
            require(new == old, f"immutable source changed: {path}")
        if path in {"CHANGES.md", ".lux/sources.sha256"} and old is not None:
            require(new is not None and new.startswith(old), f"append-only file rewritten: {path}")
    for path in changed:
        if path.startswith("inbox/") and path not in after:
            require(any(after[p] == before[path] for p in after if p.startswith("sources/")),
                    f"inbox deleted without literal source: {path}")
    if not changed:
        return
    require("CHANGES.md" in changed, "mutation requires an append-only CHANGES entry")
    if message is None:
        return
    meta = trailers(message)
    actor = meta.get("Lux-Actor")
    require(actor in {"human", "agent", "cli"}, "exactly one Lux-Actor trailer is required")
    operation = meta.get("Lux-Operation", "")
    override = meta.get("Lux-Override", "")
    if override:
        require(actor == "human" and override in after["CHANGES.md"][len(before.get("CHANGES.md", b"")):].decode(),
                "human override needs its exact reason appended to CHANGES")
    cli_paths = {
        "add": ("inbox/",),
        "checkout": ("sources/", "TODAY.md", ".lux/sources.sha256", "INDEX.md"),
        "spec-new": ("specs/", "INDEX.md"),
        "gate-approve": ("specs/",),
        "remind-add": ("reminders/",),
        "remind-done": ("reminders/",),
        "remind-rm": ("reminders/",),
    }
    if actor == "cli":
        require(operation in cli_paths, "CLI commit requires a known Lux-Operation")
        require(f"CLI {operation}".encode() in after["CHANGES.md"][len(before.get("CHANGES.md", b"")):],
                "CLI operation needs its matching append-only log entry")
    for path in changed:
        owner, rule = ownership(rules, path)
        old, new = before.get(path), after.get(path)
        if path.startswith("specs/") and gates(old or b"") != gates(new or b""):
            # A new empty Gates section is not an approval.
            substantive = lambda value: re.sub(r"<!--.*?-->", "", value, flags=re.S).strip()
            altered = substantive(gates(old or b"")) != substantive(gates(new or b""))
            if altered:
                require(actor == "cli" and operation == "gate-approve" and old is not None and new is not None,
                        "gate records may only be appended by gate-approve")
                require(gates(new).startswith(gates(old)), "gate history rewritten")
                record = gates(new)[len(gates(old)):].strip()
                require(re.fullmatch(r"- G\d+: approved \d{4}-\d{2}-\d{2}T[^ \n]+ via local terminal", record),
                        "invalid gate approval record")
        if actor == "cli":
            allowed = path == "CHANGES.md" or any(
                path.startswith(item) if item.endswith("/") else path == item for item in cli_paths[operation]
            )
            require(allowed, f"CLI operation cannot edit {path}")
            if path in {"INDEX.md", ".lux/sources.sha256"} and old is not None:
                require(new is not None and new.startswith(old), "CLI metadata may only append")
            if operation in {"add", "spec-new"} and path.startswith(("inbox/", "specs/")):
                require(old is None and new is not None, "creation operation cannot edit existing content")
            if operation == "checkout" and path == "TODAY.md":
                def normalize(value):
                    doc = value.decode()
                    accepted = section(doc, "## Accepted Tasks")
                    normalized = re.sub(r"(?m)^- \[[ x]\] (T\d+:)", r"- [ ] \1", accepted)
                    start = re.search(r"^## Accepted Tasks\s*$", doc, re.M).end()
                    return doc[:start] + normalized + doc[start + len(accepted):]
                require(old is not None and new is not None and normalize(old) == normalize(new),
                        "checkout may only update task checkboxes")
                old_tasks = {i: state for state, i, _ in tasks(old.decode())}
                require(all(not (old_tasks[i] == "x" and state == " ") for state, i, _ in tasks(new.decode())),
                        "checkout cannot silently reopen tasks")
            if operation == "checkout" and path.startswith("sources/"):
                require(old is None and new is not None and new.startswith(b"# Checkout ")
                        and b"Immutable source: user-reported status" in new, "checkout requires a new literal checkout source")
            if operation == "gate-approve" and path.startswith("specs/"):
                require(old is not None and new is not None, "gate approval cannot create or remove a spec")
                require(old.decode().split("## Gates", 1)[0] == new.decode().split("## Gates", 1)[0],
                        "gate approval may not rewrite spec design")
                require(gates(new) != gates(old), "gate-approve must append an approval")
        else:
            triage_delete = actor == "agent" and path.startswith("inbox/") and path not in after
            require(path == "CHANGES.md" or triage_delete or owner in {actor, "shared"} or bool(override),
                    f"{actor} cannot edit {path} (owner {owner})")
            if rule == "approval-required" and path != ".lux/sources.sha256":
                require(bool(meta.get("Lux-Approval")), f"explicit Lux-Approval trailer required: {path}")


def check_command(args):
    root = Path(args.root).resolve()
    if args.range:
        base, sep, tip = args.range.partition("..")
        require(sep and base and tip and ".." not in tip, "use --range BASE..TIP")
        base = git(root, "rev-parse", "--verify", base + "^{commit}").decode().strip()
        tip = git(root, "rev-parse", "--verify", tip + "^{commit}").decode().strip()
        subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", base, tip], check=True)
        for commit in git(root, "rev-list", "--reverse", f"{base}..{tip}").decode().splitlines():
            parents = git(root, "rev-list", "--parents", "-n", "1", commit).decode().split()[1:]
            require(len(parents) == 1, "merge commits require separate reviewed adoption; no first-parent shortcut")
            before, after = snapshot(root, parents[0]), snapshot(root, commit)
            validate(after, root)
            transition(before, after, git(root, "show", "-s", "--format=%B", commit).decode())
    else:
        after = snapshot(root, ":" if args.staged else None)
        validate(after, root, local=not args.staged)
        if args.staged:
            before = snapshot(root, "HEAD")
            transition(before, after, Path(args.message).read_text() if args.message else None)
    print("PASS: G3 document and snapshot validation")


def prepare(args):
    root, output = Path(args.root).resolve(), Path(args.output)
    files = snapshot(root)
    updates = {}
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    if args.action == "checkout":
        document = text(files, "TODAY.md")
        accepted = tasks(document)
        selected = args.done.split(",") if args.done else []
        require(len(selected) == len(set(selected)), "duplicate selected task ID")
        known = {i for _, i, _ in accepted}
        require(set(selected) <= known, "unknown or proposed task ID")
        require({i for state, i, _ in accepted if state == "x"} <= set(selected), "reopening task requires clarification")
        updated = document
        for state, identity, _ in accepted:
            updated = re.sub(rf"(?m)^- \[{state}\] {identity}:", f"- [{'x' if identity in selected else ' '}] {identity}:", updated)
        updates["TODAY.md"] = updated.encode()
        name = f"sources/{now[:10]}-checkout-{os.urandom(8).hex()}.md"
        source = f"# Checkout {now}\n\nImmutable source: user-reported status, not independent verification.\n\nDone IDs: {args.done}\n\nComment:\n{args.comment}\n"
        updates[name] = source.encode()
        updates[".lux/sources.sha256"] = files[".lux/sources.sha256"] + f"{hashlib.sha256(updates[name]).hexdigest()}  {name}\n".encode()
        updates["INDEX.md"] = files["INDEX.md"] + f"\n- [{name}]({name}): Immutable user checkout, {now[:10]}.\n".encode()
    else:
        require(re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.slug), "slug must be ASCII kebab-case")
        name = f"specs/{args.slug}.md"
        if args.action == "spec-new":
            require(name not in files, "spec already exists")
            template = text(files, "system/templates/spec.md").replace("{{title}}", args.slug)
            require("{{" not in template, "unknown template placeholder")
            require(re.findall(r"^- G(\d+): .+$", section(template, "## 6. Phases"), re.M), "template needs phase IDs")
            updates[name] = template.encode()
            updates["INDEX.md"] = files["INDEX.md"] + f"\n- [{name}]({name}): Proposed spec {args.slug}.\n".encode()
        elif args.action == "gate-approve":
            doc = text(files, name)
            phases = re.findall(r"^- (G\d+): .+$", section(doc, "## 6. Phases"), re.M)
            require(phases and len(phases) == len(set(phases)), "missing or duplicate phase IDs")
            require(phases == [f"G{i}" for i in range(1, len(phases) + 1)], "phase IDs must be sequential G1..Gn")
            approvals = re.findall(r"^- (G\d+): approved .+$", section(doc, "## Gates"), re.M)
            require(approvals == phases[:len(approvals)], "existing approvals are not sequential")
            require(len(approvals) < len(phases) and phases[len(approvals)] == args.gate, "approve the next unapproved gate")
            require(doc.rstrip().endswith(section(doc, "## Gates").rstrip()), "Gates must be the final section")
            updates[name] = (doc.rstrip() + f"\n\n- {args.gate}: approved {now} via local terminal\n").encode()
    for name, data in updates.items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    print("\n".join(updates))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("--root", required=True)
    check.add_argument("--staged", action="store_true")
    check.add_argument("--message")
    check.add_argument("--range")
    prep = sub.add_parser("prepare")
    prep.add_argument("--root", required=True)
    prep.add_argument("--output", required=True)
    prep.add_argument("--action", choices=["checkout", "spec-new", "gate-approve"], required=True)
    prep.add_argument("--done", default="")
    prep.add_argument("--comment", default="")
    prep.add_argument("--slug", default="")
    prep.add_argument("--gate", default="")
    args = parser.parse_args()
    try:
        if args.command == "check":
            require(not (args.range and (args.staged or args.message)), "range and staged/message are exclusive")
            require(not args.message or args.staged, "message requires staged")
            check_command(args)
        else:
            prepare(args)
    except (Invalid, ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"lux: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
