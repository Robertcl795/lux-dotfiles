#!/usr/bin/env bash

lux_error() { printf 'lux: %s\n' "$*" >&2; return 1; }
lux_usage_error() { printf 'lux: %s\n' "$*" >&2; exit 2; }

lux_context() {
    local dir configured machine=personal requested=${LUX_MODE:-} work_root actual
    LUX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/lux"
    if [[ -z ${LUX_VAULT:-} ]]; then
        dir=$PWD
        while [[ $dir != / ]]; do
            if [[ -f $dir/INDEX.md && -f $dir/.lux/ownership ]]; then
                LUX_VAULT=$dir
                break
            fi
            dir=$(dirname -- "$dir")
        done
        if [[ -z ${LUX_VAULT:-} && -f $LUX_CONFIG/default-vault ]]; then
            IFS= read -r configured < "$LUX_CONFIG/default-vault" || [[ -n $configured ]]
            LUX_VAULT=$configured
        fi
    fi
    [[ -n ${LUX_VAULT:-} ]] || { lux_error 'no vault; use --vault PATH or install a default vault'; return 1; }
    LUX_VAULT=$(realpath -e -- "$LUX_VAULT") || return 1
    [[ -d $LUX_VAULT && $LUX_VAULT != *$'\n'* ]] || { lux_error 'invalid vault path'; return 1; }
    for configured in INDEX.md INSTRUCTIONS.md .lux/ownership; do
        lux_path "$configured" >/dev/null || return 1
        [[ -f $LUX_VAULT/$configured ]] || { lux_error "not a Lux vault: missing $configured"; return 1; }
    done
    if [[ -f $LUX_CONFIG/machine ]]; then
        machine=$(cat -- "$LUX_CONFIG/machine")
    fi
    [[ $machine == personal || $machine == work ]] || { lux_error 'invalid machine mode'; return 1; }
    [[ -z $requested || $requested == personal || $requested == work ]] || { lux_error 'invalid LUX_MODE'; return 1; }
    LUX_EFFECTIVE_MODE=$machine
    LUX_MODE_REASON="machine=$machine"
    work_root=$(realpath -m -- "${LUX_WORK_ROOT:-$HOME/work}")
    actual=$(realpath -e -- "$PWD")
    if [[ $requested == work || $actual == "$work_root" || $actual == "$work_root/"* || $LUX_VAULT == "$work_root" || $LUX_VAULT == "$work_root/"* ]]; then
        LUX_EFFECTIVE_MODE=work
        LUX_MODE_REASON+='; work restriction from environment or directory'
    fi
    if [[ $requested == personal && $LUX_EFFECTIVE_MODE == work ]]; then
        lux_error 'personal mode cannot downgrade a work restriction'
        return 1
    fi
    if [[ $LUX_EFFECTIVE_MODE == work ]]; then
        [[ -f $LUX_VAULT/.lux/mode && $(cat -- "$LUX_VAULT/.lux/mode") == work ]] || {
            lux_error 'work context requires an explicitly marked local work vault (.lux/mode = work)'
            return 1
        }
        git -C "$LUX_VAULT" rev-parse --git-dir >/dev/null || { lux_error 'work vault must be a local Git repository'; return 1; }
        [[ -z $(git -C "$LUX_VAULT" remote) ]] || { lux_error 'work vault must not have a Git remote'; return 1; }
    fi
    LUX_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lux/$(printf '%s' "$LUX_VAULT" | sha256sum | cut -d ' ' -f1)"
}

lux_path() {
    local rel=$1 resolved
    [[ $rel != /* && $rel != *$'\n'* && $rel != .. && $rel != ../* && $rel != */../* && $rel != */.. ]] || {
        lux_error 'unsafe relative path'; return 1
    }
    resolved=$(realpath -m -- "$LUX_VAULT/$rel") || return 1
    [[ $resolved == "$LUX_VAULT/"* ]] || { lux_error "path escapes vault: $rel"; return 1; }
    [[ ! -L $LUX_VAULT/$rel ]] || { lux_error "symlink destination is not writable by Lux: $rel"; return 1; }
    printf '%s\n' "$resolved"
}

lux_mode() {
    printf 'mode: %s\nvault: %s\nreason: %s\n' "$LUX_EFFECTIVE_MODE" "$LUX_VAULT" "$LUX_MODE_REASON"
    printf 'Isolation: advisory context only; no agent or credential sandbox in alpha.\n'
}

lux_lock() {
    mkdir -p -- "$LUX_STATE"
    chmod 700 -- "$LUX_STATE"
    exec {LUX_LOCK_FD}> "$LUX_STATE/lock"
    flock -x "$LUX_LOCK_FD"
    [[ ! -e $LUX_STATE/pending ]] || {
        lux_error "unfinished transaction; review $LUX_STATE/pending before further writes"
        return 1
    }
}

lux_digest() {
    if [[ -f $1 ]]; then sha256sum -- "$1" | cut -d ' ' -f1
    elif [[ -e $1 ]]; then lux_error 'destination is not a regular file'; return 1
    else printf 'absent\n'; fi
}

lux_tx_begin() {
    lux_lock || return 1
    LUX_TX=$(mktemp -d "$LUX_STATE/prepare.XXXXXXXX")
    trap '[[ -z ${LUX_TX:-} || ! -d $LUX_TX ]] || rm -r -- "$LUX_TX"' EXIT
    mkdir "$LUX_TX/files"
    : > "$LUX_TX/baseline"
}

lux_stage() {
    local rel=$1 path hash pattern owner _rule matched=0
    path=$(lux_path "$rel") || return 1
    while read -r pattern owner _rule; do
        [[ -n $pattern && $pattern != \#* ]] || continue
        # Ownership rows intentionally contain shell glob patterns.
        # shellcheck disable=SC2053
        if [[ $rel == $pattern ]]; then
            [[ $owner =~ ^(human|agent|shared|cli)$ ]] || { lux_error 'invalid ownership manifest'; return 1; }
            matched=1
            break
        fi
    done < "$LUX_VAULT/.lux/ownership"
    ((matched)) || { lux_error "unowned write destination: $rel"; return 1; }
    LUX_STAGED="$LUX_TX/files/$rel"
    if [[ ! -e $LUX_STAGED ]]; then
        hash=$(lux_digest "$path") || return 1
        printf '%s %s\n' "$hash" "$rel" >> "$LUX_TX/baseline"
        mkdir -p -- "$(dirname -- "$LUX_STAGED")"
        if [[ $hash == absent ]]; then : > "$LUX_STAGED"; else cp -- "$path" "$LUX_STAGED"; fi
    fi
}

lux_log() {
    lux_stage CHANGES.md || return 1
    printf '\n## %s - CLI %s\n\n- %s\n' "$(date -Iseconds)" "$1" "$2" >> "$LUX_STAGED"
}

lux_tx_commit() {
    local hash rel path tmp
    while IFS=' ' read -r hash rel; do
        path=$(lux_path "$rel") || return 1
        [[ $(lux_digest "$path") == "$hash" ]] || { lux_error "concurrent edit: $rel; no transaction applied"; return 1; }
    done < "$LUX_TX/baseline"
    mv -- "$LUX_TX" "$LUX_STATE/pending"
    LUX_TX=''
    while IFS=' ' read -r hash rel; do
        path=$(lux_path "$rel") || return 1
        [[ $(lux_digest "$path") == "$hash" ]] || { lux_error "concurrent edit: $rel; transaction remains in $LUX_STATE/pending"; return 1; }
        mkdir -p -- "$(dirname -- "$path")"
        tmp=$(mktemp "$(dirname -- "$path")/.lux-write.XXXXXXXX")
        if ! cp -- "$LUX_STATE/pending/files/$rel" "$tmp" || ! mv -T -- "$tmp" "$path"; then
            rm -f -- "$tmp"
            lux_error "partial transaction; recover using $LUX_STATE/pending"
            return 1
        fi
    done < "$LUX_STATE/pending/baseline"
    rm -r -- "$LUX_STATE/pending"
}

lux_add() {
    [[ $# -le 1 ]] || lux_usage_error 'add takes a single text argument or stdin'
    lux_tx_begin
    local input="$LUX_TX/input" name
    if [[ $# == 1 ]]; then
        printf '%s' "$1" > "$input"
    elif [[ ! -t 0 ]]; then
        cat > "$input"
    else
        command -v gum >/dev/null || { lux_error 'interactive capture needs gum; use lux add "text" or stdin'; return 1; }
        gum write > "$input" || return 130
    fi
    LC_ALL=C grep -q '[^[:space:]]' "$input" || { lux_error 'capture is empty'; return 1; }
    name="inbox/$(date -u '+%Y-%m-%d-%H%M%S-%N').md"
    [[ ! -e $LUX_VAULT/$name ]] || { lux_error 'capture collision'; return 1; }
    lux_stage "$name"
    printf -- '---\ncaptured: %s\nvia: cli\nmode: %s\n---\n\n' "$(date -Iseconds)" "$LUX_EFFECTIVE_MODE" > "$LUX_STAGED"
    cat -- "$input" >> "$LUX_STAGED"
    lux_log add "Captured $name; content is not a commitment."
    lux_tx_commit
    printf '%s/%s\n' "$LUX_VAULT" "$name"
}

lux_today() {
    lux_path TODAY.md >/dev/null || return 1
    [[ -f $LUX_VAULT/TODAY.md ]] || { lux_error 'missing TODAY.md'; return 1; }
    local lux_documents_tasks_date
    lux_documents_tasks_date=$(sed -n 's/^Current planning date: \([0-9-]*\)\..*/\1/p' "$LUX_VAULT/TODAY.md")
    if [[ ! $lux_documents_tasks_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$lux_documents_tasks_date" +%F >/dev/null 2>&1; then
        lux_error 'invalid or missing TODAY planning date'; return 1
    fi
    awk '
        /^## / {
            if ($0 == "## Focus") { focus++; section=1 }
            else if ($0 == "## Accepted Tasks") { accepted++; section=2 }
            else section=0
        }
        /^- \[[ x]\] T[0-9]+:/ && section==2 {
            id=$0; sub(/^- \[[ x]\] /, "", id); sub(/:.*/, "", id)
            if (seen[id]++) bad=1
        }
        section { output=output $0 "\n" }
        END {
            if (focus!=1 || accepted!=1 || bad) {
                print "lux: TODAY headings ambiguous or duplicate task IDs" > "/dev/stderr"; exit 1
            }
            printf "%s", output
        }
    ' "$LUX_VAULT/TODAY.md"
}

lux_check() {
    local file hash rel count=0
    for file in TODAY.md CHANGES.md .lux/sources.sha256 reminders/REMINDERS.md; do
        lux_path "$file" >/dev/null || return 1
        [[ -f $LUX_VAULT/$file ]] || { lux_error "missing $file"; return 1; }
    done
    lux_today >/dev/null || return 1
    awk '
        /^#/ || /^[[:space:]]*$/ {next}
        NF<2 || NF>3 || $2 !~ /^(human|shared|cli|agent)$/ {exit 1}
    ' "$LUX_VAULT/.lux/ownership" || { lux_error 'invalid ownership manifest'; return 1; }
    declare -A seen=()
    while IFS=' ' read -r hash rel; do
        [[ $hash =~ ^[a-f0-9]{64}$ && $rel == sources/* && -z ${seen[$rel]:-} ]] || {
            lux_error 'invalid or duplicate source fingerprint'; return 1
        }
        seen[$rel]=1
        file=$(lux_path "$rel") || return 1
        [[ -f $file && $(lux_digest "$file") == "$hash" ]] || { lux_error "source changed or missing: $rel"; return 1; }
        ((count+=1))
    done < "$LUX_VAULT/.lux/sources.sha256"
    while IFS= read -r -d '' file; do
        rel=${file#"$LUX_VAULT/"}
        [[ -n ${seen[$rel]:-} ]] || { lux_error "unregistered source: $rel"; return 1; }
    done < <(find "$LUX_VAULT/sources" -type f -print0)
    lux_reminders_read || return 1
    printf 'PASS: structure, task IDs, manifest syntax, %s source hashes, %s reminders\n' "$count" "${#LUX_REMINDERS[@]}"
    printf 'Document and snapshot checks run through the G3 standard-library helper.\n'
}

lux_doctor() {
    local dep policy failed=0
    lux_mode
    for dep in bash git flock realpath sha256sum date awk python3; do
        if command -v "$dep" >/dev/null; then printf 'OK: %s\n' "$dep"
        else printf 'MISSING: %s\n' "$dep"; failed=1; fi
    done
    if [[ -e $LUX_STATE/pending ]]; then printf 'ERROR: unfinished transaction at %s/pending\n' "$LUX_STATE"; failed=1; fi
    if systemctl --user is-active lux-remind.timer >/dev/null 2>&1; then
        printf 'OK: reminder timer active\n'
    else
        printf 'PENDING: reminder timer inactive; run lux remind tick manually until systemd is enabled\n'
    fi
    if [[ $(cat /proc/1/comm) != systemd ]]; then
        printf 'PENDING: systemd is not PID 1; WSL needs systemd=true and a user-initiated restart\n'
    fi
    printf 'Desktop backend: %s (delivery must be tested separately)\n' "${LUX_DESKTOP:-auto}"
    if [[ ${LUX_DESKTOP:-auto} == powershell ]] || {
        [[ ${LUX_DESKTOP:-auto} == auto ]] && grep -qi microsoft /proc/sys/kernel/osrelease
    }; then
        if command -v powershell.exe >/dev/null; then
            if policy=$(powershell.exe -NoProfile -NonInteractive -Command Get-ExecutionPolicy | tr -d '\r'); then
                printf 'Windows script policy: %s\n' "$policy"
                if [[ $policy == Restricted || $policy == AllSigned ]]; then
                    printf 'BLOCKED: desktop script needs an IT-approved execution/signing route; no bypass applied\n'
                    failed=1
                fi
            else
                printf 'ERROR: unable to inspect Windows script policy\n'
                failed=1
            fi
        else
            printf 'MISSING: powershell.exe for Windows desktop delivery\n'
            failed=1
        fi
    fi
    printf 'Mobile: %s; work mode always forbids it\n' "${LUX_MOBILE:-off}"
    if [[ -L $(git -C "$LUX_VAULT" rev-parse --path-format=absolute --git-path hooks/pre-commit) ]]; then
        printf 'Hooks: installed (commit validation only; not authentication)\n'
    else
        printf 'Hooks: not installed; use lux hooks install after a reviewed policy checkpoint\n'
    fi
    printf 'PENDING: full G5 isolation and G6 bootstrap; G4 notification blockers remain separate\n'
    return "$failed"
}
