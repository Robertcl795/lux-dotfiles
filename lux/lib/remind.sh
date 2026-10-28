#!/usr/bin/env bash

lux_timestamp() {
    local value=$1
    [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || {
        lux_error 'use an ISO timestamp with explicit offset, e.g. 2026-10-28T09:00:00-06:00'
        return 1
    }
    date --date="$value" +%s 2>/dev/null || { lux_error 'invalid reminder timestamp'; return 1; }
}

lux_reminders_read() {
    local path line id epoch
    path=$(lux_path reminders/REMINDERS.md) || return 1
    [[ -f $path ]] || { lux_error 'missing reminders/REMINDERS.md'; return 1; }
    LUX_REMINDERS=()
    LUX_MAX_ID=0
    declare -A seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == '- ['* ]] || continue
        [[ $line =~ ^-\ \[([x\ -])\]\ (R[0-9]{6})\ ([^[:space:]]+)\ (.+)$ ]] || {
            lux_error 'malformed reminder line (alpha requires six-digit IDs and timezone offsets)'; return 1
        }
        id=${BASH_REMATCH[2]}
        [[ -z ${seen[$id]:-} ]] || { lux_error "duplicate reminder: $id"; return 1; }
        seen[$id]=1
        epoch=$(lux_timestamp "${BASH_REMATCH[3]}") || return 1
        [[ -n $epoch ]] || return 1
        LUX_REMINDERS+=("$line")
        id=$((10#${id#R}))
        ((id<=LUX_MAX_ID)) || LUX_MAX_ID=$id
    done < "$path"
}

lux_remind() {
    local action=${1:-} text at epoch id file line found=0 status
    [[ $# -ge 1 ]] && shift
    case "$action" in
        list)
            [[ $# == 0 ]] || lux_usage_error 'remind list takes no arguments'
            lux_reminders_read
            if ((${#LUX_REMINDERS[@]})); then printf '%s\n' "${LUX_REMINDERS[@]}"; fi
            ;;
        add)
            [[ $# == 3 && $2 == --at ]] || lux_usage_error 'remind add TEXT --at ISO'
            text=$1; at=$3
            [[ $text != *$'\n'* && $text != *$'\r'* && $text =~ [^[:space:]] ]] || { lux_error 'reminder text must be nonempty and single-line'; return 1; }
            epoch=$(lux_timestamp "$at")
            at=$(date --date="@$epoch" -u '+%Y-%m-%dT%H:%M:%SZ')
            lux_tx_begin
            lux_reminders_read
            ((LUX_MAX_ID<999999)) || { lux_error 'reminder ID space exhausted'; return 1; }
            printf -v id 'R%06d' "$((LUX_MAX_ID+1))"
            lux_stage reminders/REMINDERS.md
            printf '\n- [ ] %s %s %s\n' "$id" "$at" "$text" >> "$LUX_STAGED"
            lux_log remind-add "Created $id at $at; text stays in the vault."
            lux_tx_commit
            printf '%s\n' "$id"
            ;;
        done|rm)
            [[ $# == 1 && $1 =~ ^R[0-9]{6}$ ]] || lux_usage_error 'remind done|rm R000001'
            id=$1
            lux_tx_begin
            lux_reminders_read
            for line in "${LUX_REMINDERS[@]}"; do
                if [[ $line == "- ["*"] $id "* ]]; then
                    found=1
                    [[ $line == '- [ ] '* ]] || { lux_error "$id is already completed or cancelled"; return 1; }
                fi
            done
            ((found)) || { lux_error "unknown reminder: $id"; return 1; }
            status=x
            [[ $action != rm ]] || status=-
            lux_stage reminders/REMINDERS.md
            file="$LUX_TX/reminders.new"
            awk -v id="$id" -v status="$status" '
                index($0, "- [ ] " id " ")==1 {sub(/- \[ \]/, "- [" status "]")}
                {print}
            ' "$LUX_STAGED" > "$file"
            mv -- "$file" "$LUX_STAGED"
            lux_log "remind-$action" "$id status updated; ID retained."
            lux_tx_commit
            printf '%s\n' "$id"
            ;;
        tick)
            [[ $# == 0 ]] || lux_usage_error 'remind tick takes no arguments'
            lux_tick
            ;;
        *) lux_usage_error 'use remind add|list|done|rm|tick' ;;
    esac
}

lux_desktop() {
    local id=$1 backend=${LUX_DESKTOP:-auto} script
    if [[ $backend == auto ]]; then
        if grep -qi microsoft /proc/sys/kernel/osrelease; then backend=powershell; else backend=notify-send; fi
    fi
    case "$backend" in
        notify-send)
            command -v notify-send >/dev/null || { lux_error 'notify-send is missing'; return 1; }
            notify-send --app-name=Lux 'Lux reminder' "$id"
            ;;
        powershell)
            if ! command -v powershell.exe >/dev/null || ! command -v wslpath >/dev/null; then
                lux_error 'WSL desktop delivery requires powershell.exe and wslpath'; return 1
            fi
            script=$(wslpath -w "$LUX_HOME/notify/toast.ps1") || return 1
            powershell.exe -NoProfile -NonInteractive -File "$script" -ReminderId "$id"
            ;;
        *) lux_error 'invalid desktop backend (auto, notify-send, powershell, off)' ;;
    esac
}

lux_mobile() {
    local id=$1 topic path="$LUX_CONFIG/ntfy-topic"
    [[ $LUX_EFFECTIVE_MODE == personal ]] || { lux_error 'mobile delivery is forbidden in work mode'; return 1; }
    [[ -f $path && ! -L $path && $(stat -c '%a' "$path") == 600 && -O $path ]] || {
        lux_error 'ntfy-topic must be an owned regular file with mode 600 outside the vault'; return 1
    }
    topic=$(cat -- "$path")
    [[ $topic =~ ^[a-zA-Z0-9_-]{32,128}$ ]] || { lux_error 'ntfy topic must have 32-128 URL-safe characters'; return 1; }
    command -v curl >/dev/null || { lux_error 'curl is missing'; return 1; }
    curl --silent --show-error --fail --connect-timeout 5 --max-time 15 \
        --retry 0 --proto '=https' --data-binary "Lux $id" -- "https://ntfy.sh/$topic" >/dev/null
}

lux_tick() {
    local line id at epoch now channel receipt tmp failed=0 delivered=0
    [[ ${LUX_MOBILE:-off} == off || ${LUX_MOBILE:-off} == on ]] || { lux_error 'LUX_MOBILE must be off or on'; return 1; }
    case ${LUX_DESKTOP:-auto} in auto|notify-send|powershell|off) ;; *) lux_error 'invalid desktop backend'; return 1 ;; esac
    if [[ $LUX_EFFECTIVE_MODE == work && ${LUX_MOBILE:-off} == on ]]; then
        lux_error 'mobile delivery is forbidden in work mode'; return 1
    fi
    [[ ${LUX_DESKTOP:-auto} != off || ${LUX_MOBILE:-off} != off ]] || { lux_error 'no delivery channel enabled'; return 1; }
    lux_lock
    lux_reminders_read
    now=$(date +%s)
    mkdir -p "$LUX_STATE/delivered"
    for line in "${LUX_REMINDERS[@]}"; do
        [[ $line == '- [ ] '* ]] || continue
        read -r _ _ id at _ <<< "${line#'- '}"
        epoch=$(lux_timestamp "$at") || return 1
        ((epoch<=now)) || continue
        for channel in desktop mobile; do
            [[ $channel != desktop || ${LUX_DESKTOP:-auto} != off ]] || continue
            [[ $channel != mobile || ${LUX_MOBILE:-off} == on ]] || continue
            receipt="$LUX_STATE/delivered/$id-$epoch-$channel"
            [[ ! -f $receipt ]] || continue
            if "lux_$channel" "$id"; then
                tmp=$(mktemp "$LUX_STATE/delivered/.receipt.XXXXXXXX")
                if ! date -Iseconds > "$tmp" || ! mv -T -- "$tmp" "$receipt"; then
                    rm -f -- "$tmp"
                    lux_error "$id: delivery accepted but receipt could not be saved; retry may duplicate the alert"
                    return 1
                fi
                ((delivered+=1))
            else
                lux_error "$id: $channel failed; pending retry" || :
                failed=1
            fi
        done
    done
    printf 'Accepted deliveries: %s\n' "$delivered"
    return "$failed"
}
