#!/usr/bin/env bash

lux_documents() {
    command -v python3 >/dev/null || { lux_error 'G3 documents require Python 3 (standard library only)'; return 1; }
    python3 "$LUX_HOME/lib/documents.py" "$@"
}

lux_prepare() {
    local rel list
    list=$(lux_documents prepare --root "$LUX_VAULT" --output "$LUX_TX/generated" "$@") || return 1
    while IFS= read -r rel; do
        lux_stage "$rel" || return 1
        cp -- "$LUX_TX/generated/$rel" "$LUX_STAGED"
    done <<< "$list"
}

lux_checkout() {
    local selected='' comment='' provided=0 baseline tasksfile answer
    baseline=$(lux_digest "$LUX_VAULT/TODAY.md")
    lux_today >/dev/null
    while (($#)); do
        case "$1" in
            --done) [[ $# -ge 2 && $provided == 0 ]] || lux_usage_error 'provide --done exactly once'; selected=$2; provided=1; shift 2 ;;
            --comment) [[ $# -ge 2 ]] || lux_usage_error '--comment requires text'; comment=$2; shift 2 ;;
            *) lux_usage_error 'checkout [--done T001,T002 --comment TEXT]' ;;
        esac
    done
    if ((provided==0)); then
        [[ -t 0 ]] || lux_usage_error 'noninteractive checkout requires --done (empty string is valid)'
        command -v gum >/dev/null || { lux_error 'interactive checkout requires gum'; return 1; }
        tasksfile=$(awk '/^## /{inside=($0=="## Accepted Tasks")} inside && /^- \[[ x]\] T[0-9]+:/{print}' "$LUX_VAULT/TODAY.md")
        if [[ -z $tasksfile ]]; then lux_error 'no accepted tasks; record a reflection with your agent'; return 1; fi
        local -a options=() preselected=()
        while IFS= read -r answer; do
            options+=("$answer")
            [[ $answer != '- [x] '* ]] || preselected+=(--selected "$answer")
        done <<< "$tasksfile"
        answer=$(gum choose --no-limit "${preselected[@]}" -- "${options[@]}") || return 130
        selected=$(printf '%s\n' "$answer" | sed -n 's/^- \[[ x]\] \(T[0-9]*\):.*/\1/p' | paste -sd, -)
        comment=$(gum input --placeholder 'Optional checkout comment') || return 130
    fi
    lux_tx_begin
    [[ $(lux_digest "$LUX_VAULT/TODAY.md") == "$baseline" ]] || { lux_error 'TODAY changed during checkout'; return 1; }
    lux_prepare --action checkout --done "$selected" --comment "$comment"
    lux_log checkout 'User-reported task completion recorded; no independent verification.'
    lux_tx_commit
    printf 'Checkout recorded (reported, not verified).\n'
}

lux_spec() {
    [[ $# == 2 && $1 == new ]] || lux_usage_error 'spec new SLUG'
    lux_tx_begin
    lux_prepare --action spec-new --slug "$2"
    lux_log spec-new "Created proposed spec specs/$2.md."
    lux_tx_commit
    printf '%s/specs/%s.md\n' "$LUX_VAULT" "$2"
}

lux_gate() {
    [[ $# == 3 && $1 == approve && $3 =~ ^G[1-9][0-9]*$ ]] || lux_usage_error 'gate approve SLUG G1'
    [[ -t 0 && -t 1 ]] || { lux_error 'gate approval requires a human terminal; no --yes or pipe supported'; return 1; }
    [[ $2 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || lux_usage_error 'invalid spec slug'
    local path baseline reply
    path=$(lux_path "specs/$2.md")
    [[ -f $path ]] || { lux_error 'spec not found'; return 1; }
    baseline=$(lux_digest "$path")
    cat -- "$path"
    printf '\nApprove %s for %s? Type exactly "approve %s": ' "$3" "$2" "$3"
    IFS= read -r reply || return 130
    [[ $reply == "approve $3" ]] || return 130
    lux_tx_begin
    [[ $(lux_digest "$path") == "$baseline" ]] || { lux_error 'spec changed during approval'; return 1; }
    lux_prepare --action gate-approve --slug "$2" --gate "$3"
    lux_log gate-approve "Human terminal approval: $2 $3."
    lux_tx_commit
    printf 'Recorded %s for %s.\n' "$3" "$2"
}

lux_full_check() {
    if [[ $# == 0 ]]; then
        lux_check
        lux_documents check --root "$LUX_VAULT"
    else
        lux_documents check --root "$LUX_VAULT" "$@"
    fi
}

lux_commit() {
    local actor='' message='' operation='' approval='' override='' body
    while (($#)); do
        [[ $# -ge 2 ]] || lux_usage_error 'commit options require values'
        case "$1" in
            --actor) actor=$2 ;;
            -m) message=$2 ;;
            --operation) operation=$2 ;;
            --approval) approval=$2 ;;
            --override-reason) override=$2 ;;
            *) lux_usage_error 'commit --actor human|agent|cli -m TEXT [--operation OP] [--approval SOURCE] [--override-reason REASON]' ;;
        esac
        shift 2
    done
    [[ $actor =~ ^(human|agent|cli)$ && -n $message ]] || lux_usage_error 'commit requires actor and message'
    for body in "$operation" "$approval" "$override"; do
        [[ $body != *$'\n'* && $body != *$'\r'* ]] || lux_usage_error 'trailer values must be single-line'
    done
    [[ $message != *Lux-* ]] || lux_usage_error 'put Lux trailers in their named options'
    lux_lock
    git -C "$LUX_VAULT" diff --cached --quiet && { lux_error 'nothing staged'; return 1; }
    git -C "$LUX_VAULT" diff --cached --name-status >&2
    body=$(mktemp "$LUX_STATE/message.XXXXXXXX")
    printf '%s\n\nLux-Actor: %s\n' "$message" "$actor" > "$body"
    [[ -z $operation ]] || printf 'Lux-Operation: %s\n' "$operation" >> "$body"
    [[ -z $approval ]] || printf 'Lux-Approval: %s\n' "$approval" >> "$body"
    [[ -z $override ]] || printf 'Lux-Override: %s\n' "$override" >> "$body"
    printf 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>\n' >> "$body"
    if ! lux_documents check --root "$LUX_VAULT" --staged --message "$body"; then rm -- "$body"; return 1; fi
    local result=0
    git -C "$LUX_VAULT" commit -F "$body" || result=$?
    rm -- "$body"
    return "$result"
}

lux_hooks() {
    [[ $# == 1 && $1 == install ]] || lux_usage_error 'hooks install'
    local hooks existing hook target
    existing=$(git -C "$LUX_VAULT" config --get core.hooksPath || [[ $? == 1 ]])
    [[ -z $existing ]] || { lux_error 'core.hooksPath is configured; refusing to replace it'; return 1; }
    hooks=$(git -C "$LUX_VAULT" rev-parse --path-format=absolute --git-path hooks)
    for hook in pre-commit commit-msg; do
        target="$hooks/$hook"
        if [[ -e $target || -L $target ]]; then
            [[ -L $target && $(readlink -- "$target") == "$LUX_HOME/hooks/$hook" ]] || {
                lux_error "existing $hook must be reviewed before installing Lux hooks"; return 1
            }
        fi
    done
    [[ -n $(git -C "$LUX_VAULT" ls-tree HEAD -- .lux/ownership) ]] || {
        lux_error 'commit a reviewed policy adoption checkpoint before installing hooks'; return 1
    }
    mkdir -p "$hooks"
    for hook in pre-commit commit-msg; do ln -sfn "$LUX_HOME/hooks/$hook" "$hooks/$hook"; done
    printf 'Installed G3 validation hooks. They validate commits, not writer identity.\n'
}
