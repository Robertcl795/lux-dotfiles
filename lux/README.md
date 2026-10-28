# Lux 0.1.0-g3

G3 CLI core and Git validation, including the earlier reminder vertical slice.
G4 notification/runtime acceptance remains separate and unresolved on this work laptop.
Lux is a Bash CLI over a personal Markdown vault. No model, Obsidian process,
root access, network service, or database is required for capture and reading.

## Install

From this checkout:

```bash
bash lux/install.sh --vault "$HOME/second-brain"
~/.local/bin/lux --version
~/.local/bin/lux doctor
```

The installer adds a launcher in `~/.local/bin`, stores a plain-text default
vault in `${XDG_CONFIG_HOME:-~/.config}/lux/default-vault`, and installs/enables
systemd user timer files. It does not modify shell configs, replace conflicting
commands/configuration, rename repositories, or require sudo. If `~/.local/bin`
is not already on PATH, use the full command path or add it in your own shell.
Re-run the same installer after updating the checkout; conflicting existing
files must be reviewed manually, not silently replaced.

GNU/Linux dependencies: Bash, Git, GNU core utilities, util-linux (`flock`),
awk, grep and find. Optional: gum for an interactive capture. No `gum` needed
for an argument or piped input. Desktop delivery requires either `notify-send`
with a working notification session, or WSL's `powershell.exe` and `wslpath`.
The PowerShell adapter uses native Windows toast APIs, not a downloaded module.

## Use

```bash
lux add "An idea worth exploring"
printf 'An idea\nwith details\n' | lux add
lux today
lux mode
lux check

lux remind add "Review the Lux design" --at 2026-10-28T09:00:00-06:00
lux remind list
lux remind tick
lux remind done R000001
lux remind rm R000002
```

`--vault PATH` overrides `LUX_VAULT`. Otherwise Lux searches ancestors of the
current directory, then reads the installed default. All paths are
canonicalized; writes that escape the vault through symlinks are rejected.

Capture preserves body bytes, including trailing newlines, under a frontmatter
header. Filenames are unique, and CLI mutations serialize through a vault lock.
Capture is not a task commitment. `today` displays only focus and accepted
tasks. `check` checks structure, task IDs/date, manifest ownership, unique index entries,
local Markdown links and anchors, source hashes and reminder format. It reports
unsupported reference-style/ambiguous Markdown rather than guessing. Fenced
examples are ignored. Snapshot checks report external repo links as unverifiable;
worktree checks resolve them locally without network.

Reminder times require a numeric offset or `Z`; internally they are normalized
to UTC without changing the instant. Records use stable six-digit IDs
`R000001`. Done (`[x]`) and cancelled (`[-]`) records remain in Markdown so IDs
are not reused. Legacy short IDs and offset-free dates are rejected rather than
silently reinterpreted. A due delivery does not mark a reminder completed.

### Scheduling and Windows/Omarchy

The timer runs each minute and catches up on missed calendar events after the
user manager returns. The command itself delivers all overdue pending records,
so `lux remind tick` also catches up after sleep or downtime.

In WSL, edit `/etc/wsl.conf` **with sudo on your own terminal**, preserving the
other sections:

```ini
[boot]
systemd=true
```

Then, when it is safe to stop your WSL sessions, run `wsl --shutdown` from
Windows and reopen WSL. This disconnects VS Code terminals and must not be done
by an installer in the middle of a session.

```bash
systemctl --user daemon-reload
systemctl --user enable --now lux-remind.timer
systemctl --user status lux-remind.timer
journalctl --user -u lux-remind.service
```

On Omarchy, the same units use the desktop notification session. Neither the
timer nor the desktop can guarantee delivery while the machine is powered off
or the user manager is stopped. No lingering, system-wide daemon or
shell-prompt polling is installed automatically.

`LUX_DESKTOP=auto` chooses PowerShell on WSL, `notify-send` elsewhere.
Overrides: `notify-send`, `powershell`, `off`. All notification payloads contain
only `Lux` and the reminder ID, not private reminder text. Backend acceptance
does not prove a notification was visually displayed or read; Windows
notification settings/Do Not Disturb may suppress it.

Windows execution policy may also reject the `.ps1` file before it runs.
On the current work laptop, the real test was rejected for that reason.
Windows delivery therefore remains blocked pending an IT-approved
execution/signing route. Lux never changes execution policy, uses `Bypass`,
or falls back to executing the same script by another mechanism.
`lux doctor` reports restrictive policies; `tick` returns a failure and
does not save a successful delivery receipt when execution is rejected.

Receipts live in `${XDG_STATE_HOME:-~/.local/state}/lux/<vault-hash>/delivered/`.
Successful desktop/mobile deliveries are deduplicated separately across CLI
restarts on that machine. Failed channels remain due and return a nonzero exit
code, without repeating channels already accepted. Exactly-once delivery across
a crash between backend acceptance and saving the receipt is not possible:
in that window a retry can duplicate an alert. Receipts are local, not synced;
enable mobile delivery on only one personal machine. Moving the vault or
deleting receipts can repeat overdue notifications.

### Optional mobile (disabled by default)

No mobile request is sent unless `LUX_MOBILE=on`. Store a random topic of
32–128 URL-safe characters in `~/.config/lux/ntfy-topic`, mode `600`. Do not
put it in the vault or shell history. Anyone who knows a public ntfy topic may
subscribe/publish; randomness is not authentication. Use no company context.
ntfy availability, retention and mobile OS behavior are outside Lux's control.

For a manual personal-only test, once you have chosen to enable it:

```bash
LUX_MOBILE=on lux remind tick
```

Timer jobs do not inherit interactive shell variables. To opt in for the
timer, use `systemctl --user edit lux-remind.service`, adding:

```ini
[Service]
Environment=LUX_MOBILE=on
```

Then reload the user manager. Do not put the topic in the unit. This delivery
has been validated with local mocks only; installation does not opt you in.

## Work context and alpha boundaries

`LUX_MODE=work`, a `work` machine setting in `~/.config/lux/machine`, or a path
under `~/work` imposes work restrictions. Set `LUX_WORK_ROOT` for a different
local root. Personal cannot override a work restriction. Work mode requires
`.lux/mode` containing `work`, a local Git repository with no remotes, and
always rejects mobile delivery.

This is context routing, **not** process isolation, credential verification or
an enforced company policy. G5 still owns work-vault setup, account isolation,
read-only preference exports and backups. Temporary personal development on
the work laptop is the previously approved D1 exception; keep work material out.

G3 now includes checkout, spec creation, human-terminal approval recording,
staged commits, optional hooks and commit-range validation. Deferred: sync,
agent launching, MCP, habits, private-vault CI deployment, one-command system
bootstrap and Omarchy customization. Do not infer completion of G4/G5/G6.

## G3 workflows and Git validation

Python 3 (standard library only) is required for documents and snapshots.
Bash continues to own dispatch, locks, transaction recovery and notifications.

```bash
lux checkout --done T001,T002 --comment "User-reported completion"
lux spec new example-design
# Human in their own terminal; never an agent approving its own work:
lux gate approve example-design G1
lux check --staged
lux check --range BASE..HEAD
lux commit --actor agent -m "Update lessons"
```

`lux checkout` without options uses gum if installed, preselects completed
accepted tasks, and records the chosen IDs plus optional comment. Explicit
empty selection is `--done ""`, allowed only when it does not reopen a completed
task. Unknown/proposed IDs, duplicate IDs and silent reopening are rejected.
Checkout updates only accepted checkboxes and adds an immutable source,
fingerprint, index entry and log; it does not synthesize the journal.

Specs use the vault's `system/templates/spec.md`, with phase IDs under
`## 6. Phases` (`- G1: Design`, `- G2: Implementation`) and a final `## Gates`.
Gate approval requires a terminal and the exact confirmation `approve G1`.
It rejects out-of-order/duplicate approvals. Legacy free-form specs require a
reviewed migration; their records are never silently inferred or rewritten.
Interactive cancellation writes nothing. A terminal is friction, not proof
that a human is operating it.

Git validation uses blob snapshots from the index/commit, not working files.
It checks each transition against the **previous** ownership manifest, rejects
rewritten/deleted sources even if their hash is updated, and preserves the
prefix of CHANGES and the hash manifest. Inbox deletion by an agent requires
byte-for-byte preservation in a source. Each mutation requires an appended
CHANGES entry. Commit ranges reject merges rather than silently skipping a
parent. Use a reviewed checkpoint to adopt pre-policy history; it is not
retrospectively certified by G3.

Actor trailers are advisory audit metadata, not signatures. Agent-owned,
human-owned and CLI-owned paths cannot be mixed in one actor commit except
documented CLI operation metadata and shared paths. CLI commits require a
matching operation (e.g. `--actor cli --operation checkout`), limited paths
and its matching `CLI checkout` log entry. Permission-changing or rule changes
also require `--approval "source or user authorization"`.

An exceptional human memory edit requires its exact reason appended in
CHANGES, then:

```bash
lux commit --actor human -m "Reviewed correction" --override-reason "exact reason"
```

Use `--approval` too when an approval-required path is involved. No override
permits source/log/gate rewriting, authorizes unknown paths or circumvents
work-mode restrictions. No `LUX_OVERRIDE=1` bypass exists.

`lux commit` commits **only already staged files**, adds actor/coauthor trailers,
and does not stage, push or grant itself authorization. Request any commit
explicitly. It refuses a repository with no reviewed policy baseline in HEAD.

`lux hooks install` explicitly installs pre-commit and commit-msg symlinks in
the vault's Git hooks directory. It requires the committed adoption checkpoint,
is idempotent and refuses conflicts or custom core.hooksPath. It never replaces
third-party hooks. Hooks can be bypassed by Git; they are not filesystem access
control, authentication, company isolation or a sanitization guarantee.
Keep this dotfiles checkout at its configured path until reinstalling hooks
after a future rename.

Public CI runs `make test-lux` on synthetic data only. It never fetches a vault,
company context, personal sources or local denylist. A local corporate denylist,
if required by policy, is an additional separate control, not a CI guarantee.

### Recovery

Multi-file writes stage first, check for external edits, and replace each file
atomically. This is not an atomic transaction across several files. If failure
occurs after application starts, Lux leaves `pending/baseline` and
`pending/files/` in its state directory and blocks further mutations.

Inspect the named recovery directory and compare each file against the vault.
Reconcile manually without overwriting newer edits. Keep a copy of the pending
directory, then move it out of the `pending` name only after all listed files
are consistent. Never erase evidence just to make the error disappear.
Read-only commands remain available. Concurrent writes by Obsidian cannot
share the Bash lock; hash checks reduce but cannot eliminate every final
check-to-rename race. Do not edit the same file while a CLI mutation runs.

## Tests and Git workflow

```bash
make test-lux
```

Requires Bats, ShellCheck and Python 3 on PATH. Tests create synthetic vaults and mock
every notification backend. No personal vault, system hooks, credentials or
remote ntfy endpoint is used. Existing system checkpoint tests are unchanged.

Use **GitHub Flow**, not Git Flow: stable `main`, short-lived `feature/*`
branches, review the exact diff, merge after tests, then tag a verified release.
No permanent `develop`/`release/*` branches are needed for one maintainer and
one release line. Adopt Git Flow only if parallel long-lived release support
actually demands it. The G3 checkpoint tag is `lux-g3-v0.1.0`; it is not a
claim that the full G4/G5/G6 MVP has shipped. Do not include unrelated
pre-existing changes in a Lux commit.
