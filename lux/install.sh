#!/usr/bin/env bash
set -euo pipefail
umask 077

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $# == 2 && $1 == --vault ]] || { printf 'Usage: bash lux/install.sh --vault PATH\n' >&2; exit 2; }
vault=$(realpath -e -- "$2")
bash "$root/bin/lux" --vault "$vault" check
bin="$HOME/.local/bin"
config="${XDG_CONFIG_HOME:-$HOME/.config}/lux"
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$bin" "$config" "$units"
if [[ -e $bin/lux || -L $bin/lux ]]; then
    [[ -L $bin/lux && $(readlink -- "$bin/lux") == "$root/bin/lux" ]] || {
        printf 'Refusing to overwrite existing %s/lux\n' "$bin" >&2; exit 1
    }
fi
if [[ -f $config/default-vault && $(cat "$config/default-vault") != "$vault" ]]; then
    printf 'Default vault differs; review %s/default-vault first\n' "$config" >&2
    exit 1
fi
[[ ! -L $config/default-vault ]] || { printf 'Refusing symlink default-vault\n' >&2; exit 1; }
for unit in lux-remind.service lux-remind.timer; do
    [[ ! -L $units/$unit ]] || { printf 'Refusing symlink unit: %s\n' "$unit" >&2; exit 1; }
    if [[ -e $units/$unit ]]; then
        cmp -s "$root/systemd/$unit" "$units/$unit" || {
            printf 'Refusing to overwrite different %s\n' "$units/$unit" >&2; exit 1
        }
    fi
done
chmod +x "$root/bin/lux"
ln -sfn "$root/bin/lux" "$bin/lux"
printf '%s\n' "$vault" > "$config/default-vault"
for unit in lux-remind.service lux-remind.timer; do
    cp "$root/systemd/$unit" "$units/$unit"
done
printf 'Installed %s/lux and user timer files. Mobile remains off.\n' "$bin"
systemctl --user enable lux-remind.timer
if systemctl --user daemon-reload; then
    systemctl --user start lux-remind.timer
else
    printf 'PENDING: timer enabled on disk, but no systemd user manager is running. Enable systemd and restart WSL, then check:\n  systemctl --user status lux-remind.timer\n' >&2
fi
