#!/usr/bin/env bats

setup() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_STATE_HOME="$HOME/.local/state"
    export LUX_VAULT="$HOME/vault with spaces"
    export LUX_DESKTOP=notify-send LUX_MOBILE=off
    unset LUX_MODE LUX_WORK_ROOT
    export MOCK_DELIVERIES="$BATS_TEST_TMPDIR/desktop"
    export MOCK_MOBILE="$BATS_TEST_TMPDIR/mobile"
    export PATH="$BATS_TEST_DIRNAME/helpers:$PATH"
    export LUX_BIN="$BATS_TEST_DIRNAME/../bin/lux"
    mkdir -p "$LUX_VAULT"/{.lux,inbox,sources,reminders,designs,resources,system/templates,.github} "$XDG_CONFIG_HOME/lux"
    printf '# Index\n- [INSTRUCTIONS.md](INSTRUCTIONS.md)\n- [TODAY.md](TODAY.md)\n- [CHANGES.md](CHANGES.md)\n- [reminders/REMINDERS.md](reminders/REMINDERS.md)\n- [inbox/](inbox/)\n- [designs/](designs/)\n- [resources/](resources/)\n- [system/templates/](system/templates/)\n- [.github/](.github/)\n' > "$LUX_VAULT/INDEX.md"
    printf '# Rules\n' > "$LUX_VAULT/INSTRUCTIONS.md"
    printf '# Changes\n' > "$LUX_VAULT/CHANGES.md"
    printf 'inbox/** human preserve-before-delete\nsources/** agent append-only\n** agent\n' > "$LUX_VAULT/.lux/ownership"
    : > "$LUX_VAULT/.lux/sources.sha256"
    printf '# Reminders\n' > "$LUX_VAULT/reminders/REMINDERS.md"
    cat > "$LUX_VAULT/TODAY.md" <<'EOF'
# Today
Current planning date: 2026-10-27.
## Focus
Ship the alpha
## Accepted Tasks
- [ ] T001: First task
- [x] T002: Completed
## Proposed Tasks
- P1: Not accepted
EOF
}

@test "version and help need no vault" {
    run env -u LUX_VAULT bash "$LUX_BIN" --version
    [ "$status" -eq 0 ]
    [ "$output" = "0.1.0-g3" ]
    run bash "$LUX_BIN" --help
    [ "$status" -eq 0 ]
}

@test "unknown command is a usage error and deferred commands are not fake successes" {
    run bash "$LUX_BIN" nonexistent
    [ "$status" -eq 2 ]
}

@test "capture stdin preserves all body bytes including trailing newlines" {
    printf 'Idea\n\nMore\n\n' > "$BATS_TEST_TMPDIR/body"
    bash "$LUX_BIN" add < "$BATS_TEST_TMPDIR/body" > "$BATS_TEST_TMPDIR/path"
    file=$(cat "$BATS_TEST_TMPDIR/path")
    tail -n +7 "$file" > "$BATS_TEST_TMPDIR/actual"
    cmp "$BATS_TEST_TMPDIR/body" "$BATS_TEST_TMPDIR/actual"
    grep -q 'CLI add' "$LUX_VAULT/CHANGES.md"
}

@test "empty capture does not mutate vault" {
    before=$(sha256sum "$LUX_VAULT/CHANGES.md")
    run bash "$LUX_BIN" add '   '
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$LUX_VAULT/inbox")" ]
    [ "$before" = "$(sha256sum "$LUX_VAULT/CHANGES.md")" ]
}

@test "concurrent captures produce unique files and append each log entry" {
    pids=()
    for n in {1..8}; do
        bash "$LUX_BIN" add "Idea $n" > /dev/null &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    [ "$(find "$LUX_VAULT/inbox" -type f | wc -l)" -eq 8 ]
    [ "$(grep -c 'CLI add' "$LUX_VAULT/CHANGES.md")" -eq 8 ]
}

@test "capture rejects directory symlink escape" {
    mkdir "$BATS_TEST_TMPDIR/outside"
    rmdir "$LUX_VAULT/inbox"
    ln -s "$BATS_TEST_TMPDIR/outside" "$LUX_VAULT/inbox"
    run bash "$LUX_BIN" add secret
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/outside")" ]
}

@test "today includes accepted tasks and excludes proposals" {
    run bash "$LUX_BIN" today
    [ "$status" -eq 0 ]
    [[ "$output" == *T001* && "$output" == *T002* ]]
    [[ "$output" != *'Not accepted'* ]]
}

@test "today rejects duplicate open task IDs" {
    sed -i '/## Accepted Tasks/a - [ ] T001: duplicate' "$LUX_VAULT/TODAY.md"
    run bash "$LUX_BIN" today
    [ "$status" -ne 0 ]
    [[ "$output" == *duplicate* ]]
}

@test "source fingerprints and unregistered sources fail explicitly" {
    printf 'original\n' > "$LUX_VAULT/sources/original.md"
    run bash "$LUX_BIN" check
    [ "$status" -ne 0 ]
    [[ "$output" == *unregistered* ]]
    (cd "$LUX_VAULT" && sha256sum sources/original.md > .lux/sources.sha256)
    printf '\n- [sources/original.md](sources/original.md)\n' >> "$LUX_VAULT/INDEX.md"
    run bash "$LUX_BIN" check
    [ "$status" -eq 0 ]
    printf 'modified\n' >> "$LUX_VAULT/sources/original.md"
    run bash "$LUX_BIN" check
    [ "$status" -ne 0 ]
}

@test "machine work restriction cannot be downgraded" {
    printf 'work\n' > "$XDG_CONFIG_HOME/lux/machine"
    run env LUX_MODE=personal bash "$LUX_BIN" mode
    [ "$status" -ne 0 ]
    [[ "$output" == *downgrade* ]]
}

@test "work mode requires marked local work vault and disallows mobile" {
    git -C "$LUX_VAULT" init -q
    printf 'work\n' > "$LUX_VAULT/.lux/mode"
    run env LUX_MODE=work LUX_MOBILE=on bash "$LUX_BIN" remind tick
    [ "$status" -ne 0 ]
    [[ "$output" == *forbidden* ]]
    [ ! -e "$MOCK_MOBILE" ]
    git -C "$LUX_VAULT" remote add origin https://example.invalid/repo
    run env LUX_MODE=work bash "$LUX_BIN" mode
    [ "$status" -ne 0 ]
    [[ "$output" == *remote* ]]
}

@test "timestamps require offsets and reject impossible dates" {
    run bash "$LUX_BIN" remind add Text --at 2026-10-28T09:00
    [ "$status" -ne 0 ]
    run bash "$LUX_BIN" remind add Text --at 2026-02-30T09:00:00-06:00
    [ "$status" -ne 0 ]
    [ "$(cat "$LUX_VAULT/reminders/REMINDERS.md")" = '# Reminders' ]
}

@test "reminder converts explicit offset without losing the instant" {
    run bash "$LUX_BIN" remind add 'Review design' --at 2030-10-28T09:00:00-06:00
    [ "$status" -eq 0 ]
    [ "$output" = R000001 ]
    grep -q '2030-10-28T15:00:00Z' "$LUX_VAULT/reminders/REMINDERS.md"
}

@test "done and cancel preserve IDs and new IDs are monotonic" {
    bash "$LUX_BIN" remind add First --at 2020-01-01T00:00Z > /dev/null
    bash "$LUX_BIN" remind done R000001
    grep -q -- '- \[x\] R000001' "$LUX_VAULT/reminders/REMINDERS.md"
    bash "$LUX_BIN" remind add Second --at 2020-01-01T00:00Z > /dev/null
    bash "$LUX_BIN" remind rm R000002
    grep -q -- '- \[-\] R000002' "$LUX_VAULT/reminders/REMINDERS.md"
    run bash "$LUX_BIN" remind add Third --at 2020-01-01T00:00Z
    [ "$status" -eq 0 ]
    [ "$output" = R000003 ]
    run bash "$LUX_BIN" remind tick
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_DELIVERIES")" -eq 1 ]
}

@test "tick delivers overdue once per channel without checking off reminders" {
    bash "$LUX_BIN" remind add 'Private text' --at 2020-01-01T00:00Z > /dev/null
    bash "$LUX_BIN" remind tick
    bash "$LUX_BIN" remind tick
    [ "$(wc -l < "$MOCK_DELIVERIES")" -eq 1 ]
    ! grep -q 'Private text' "$MOCK_DELIVERIES"
    grep -q -- '- \[ \] R000001' "$LUX_VAULT/reminders/REMINDERS.md"
}

@test "future reminders are not delivered" {
    bash "$LUX_BIN" remind add Future --at 2099-01-01T00:00Z > /dev/null
    run bash "$LUX_BIN" remind tick
    [ "$status" -eq 0 ]
    [ ! -e "$MOCK_DELIVERIES" ]
}

@test "failed channel retries without duplicating successful channel" {
    printf 'LuxTestTopic012345678901234567890123456789\n' > "$XDG_CONFIG_HOME/lux/ntfy-topic"
    chmod 600 "$XDG_CONFIG_HOME/lux/ntfy-topic"
    bash "$LUX_BIN" remind add Secret --at 2020-01-01T00:00Z > /dev/null
    run env LUX_MOBILE=on MOCK_MOBILE_FAIL=1 bash "$LUX_BIN" remind tick
    [ "$status" -ne 0 ]
    [ "$(wc -l < "$MOCK_DELIVERIES")" -eq 1 ]
    run env LUX_MOBILE=on bash "$LUX_BIN" remind tick
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_DELIVERIES")" -eq 1 ]
    [ "$(wc -l < "$MOCK_MOBILE")" -eq 1 ]
    ! grep -q Secret "$MOCK_MOBILE"
}

@test "ntfy refuses unsafe topic permissions" {
    printf 'LuxTestTopic012345678901234567890123456789\n' > "$XDG_CONFIG_HOME/lux/ntfy-topic"
    chmod 644 "$XDG_CONFIG_HOME/lux/ntfy-topic"
    bash "$LUX_BIN" remind add Secret --at 2020-01-01T00:00Z > /dev/null
    run env LUX_MOBILE=on bash "$LUX_BIN" remind tick
    [ "$status" -ne 0 ]
    [ ! -e "$MOCK_MOBILE" ]
}

@test "PowerShell adapter passes only validated ID" {
    bash "$LUX_BIN" remind add Secret --at 2020-01-01T00:00Z > /dev/null
    run env LUX_DESKTOP=powershell bash "$LUX_BIN" remind tick
    [ "$status" -eq 0 ]
    grep -q -- '-ReminderId R000001' "$MOCK_DELIVERIES"
    ! grep -q Secret "$MOCK_DELIVERIES"
}

@test "duplicate and malformed reminder records block all delivery" {
    printf '%s\n' '- [ ] R000001 2020-01-01T00:00Z One' '- [ ] R000001 2020-01-01T00:00Z Two' >> "$LUX_VAULT/reminders/REMINDERS.md"
    run bash "$LUX_BIN" remind tick
    [ "$status" -ne 0 ]
    [ ! -e "$MOCK_DELIVERIES" ]
}

@test "pending transaction blocks mutation but permits reading" {
    state="$XDG_STATE_HOME/lux/$(printf '%s' "$LUX_VAULT" | sha256sum | cut -d ' ' -f1)"
    mkdir -p "$state/pending"
    run bash "$LUX_BIN" add Idea
    [ "$status" -ne 0 ]
    [[ "$output" == *unfinished* ]]
    run bash "$LUX_BIN" today
    [ "$status" -eq 0 ]
}

@test "concurrent edit is detected before committing the transaction" {
    run bash -c '
        set -euo pipefail
        source "$1/../lib/common.sh"
        lux_context
        lux_tx_begin
        lux_stage CHANGES.md
        printf "new staged\n" >> "$LUX_STAGED"
        printf "external edit\n" >> "$LUX_VAULT/CHANGES.md"
        lux_tx_commit
    ' _ "$(dirname "$LUX_BIN")"
    [ "$status" -ne 0 ]
    grep -q 'external edit' "$LUX_VAULT/CHANGES.md"
    ! grep -q 'new staged' "$LUX_VAULT/CHANGES.md"
}

@test "configuration data is never executed as shell" {
    printf '$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" > "$XDG_CONFIG_HOME/lux/machine"
    run bash "$LUX_BIN" mode
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "capture refuses a symlink log and leaves no half-written note" {
    printf 'external log\n' > "$BATS_TEST_TMPDIR/external"
    rm "$LUX_VAULT/CHANGES.md"
    ln -s "$BATS_TEST_TMPDIR/external" "$LUX_VAULT/CHANGES.md"
    run bash "$LUX_BIN" add Idea
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$LUX_VAULT/inbox")" ]
    [ "$(cat "$BATS_TEST_TMPDIR/external")" = 'external log' ]
}

@test "tick concurrent processes deduplicate using the vault lock" {
    bash "$LUX_BIN" remind add Text --at 2020-01-01T00:00Z > /dev/null
    bash "$LUX_BIN" remind tick > /dev/null &
    first=$!
    bash "$LUX_BIN" remind tick > /dev/null &
    second=$!
    wait "$first"
    wait "$second"
    [ "$(wc -l < "$MOCK_DELIVERIES")" -eq 1 ]
}

@test "desktop failure remains due and retries after a new process starts" {
    bash "$LUX_BIN" remind add Text --at 2020-01-01T00:00Z > /dev/null
    run env MOCK_DESKTOP_FAIL=1 bash "$LUX_BIN" remind tick
    [ "$status" -ne 0 ]
    run bash "$LUX_BIN" remind tick
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$MOCK_DELIVERIES")" -eq 1 ]
}

@test "invalid channel and multiline reminder fail before delivery or mutation" {
    run env LUX_DESKTOP=invalid bash "$LUX_BIN" remind tick
    [ "$status" -ne 0 ]
    run bash "$LUX_BIN" remind add $'First\nSecond' --at 2020-01-01T00:00Z
    [ "$status" -ne 0 ]
    [ ! -e "$MOCK_DELIVERIES" ]
}

@test "installer does not overwrite existing executable" {
    mkdir -p "$HOME/.local/bin"
    printf 'keep me\n' > "$HOME/.local/bin/lux"
    run bash "$BATS_TEST_DIRNAME/../install.sh" --vault "$LUX_VAULT"
    [ "$status" -ne 0 ]
    [ "$(cat "$HOME/.local/bin/lux")" = 'keep me' ]
}

@test "installer is idempotent and default vault works outside the vault" {
    bash "$BATS_TEST_DIRNAME/../install.sh" --vault "$LUX_VAULT"
    bash "$BATS_TEST_DIRNAME/../install.sh" --vault "$LUX_VAULT"
    [ -L "$HOME/.local/bin/lux" ]
    [ -f "$XDG_CONFIG_HOME/systemd/user/lux-remind.timer" ]
    cd "$HOME"
    run env -u LUX_VAULT "$HOME/.local/bin/lux" mode
    [ "$status" -eq 0 ]
    [[ "$output" == *"$LUX_VAULT"* ]]
}

@test "doctor reports restricted Windows execution without sending a notification" {
    run env LUX_DESKTOP=powershell MOCK_EXEC_POLICY=Restricted bash "$LUX_BIN" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *'BLOCKED: desktop script'* ]]
    [ ! -e "$MOCK_DELIVERIES" ]
}

@test "mid-transaction failure preserves recovery and blocks another write" {
    run bash -c '
        set -euo pipefail
        source "$1/../lib/common.sh"
        lux_context
        lux_tx_begin
        lux_stage inbox/recover.md
        printf "preserved idea\n" > "$LUX_STAGED"
        lux_log test "record recovery"
        mv() {
            if [[ ${*: -1} == "$LUX_VAULT/CHANGES.md" ]]; then return 1; fi
            command mv "$@"
        }
        lux_tx_commit
    ' _ "$(dirname "$LUX_BIN")"
    [ "$status" -ne 0 ]
    [[ "$output" == *'partial transaction'* ]]
    [ "$(cat "$LUX_VAULT/inbox/recover.md")" = 'preserved idea' ]
    state="$XDG_STATE_HOME/lux/$(printf '%s' "$LUX_VAULT" | sha256sum | cut -d ' ' -f1)"
    [ -f "$state/pending/files/CHANGES.md" ]
    run bash "$LUX_BIN" add Another
    [ "$status" -ne 0 ]
    [[ "$output" == *unfinished* ]]
}
