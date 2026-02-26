#!/bin/bash
# collect-macos-facts.sh
#
# Creates a snapshot of macOS settings and local tooling state to help build/verify
# Ansible automation. Review the output before sharing (hostnames, network details,
# installed apps, and optionally config files may be sensitive).
#
# Usage:
#   bash scripts/collect-macos-facts.sh
#   bash scripts/collect-macos-facts.sh --full-defaults
#   bash scripts/collect-macos-facts.sh --copy-configs
#   bash scripts/collect-macos-facts.sh -o /tmp/my-macos-snapshot
#
# Flags:
#   --full-defaults   Export all `defaults` domains (can be large; may include sensitive app prefs)
#   --copy-configs    Copy selected config files (instead of hashes only)
#   -o DIR            Output directory (default: ./macos-facts-YYYYmmdd-HHMMSS)
#   -h|--help         Show help
#
# Cleanup:
#   Keeps the most recent snapshots in the output parent directory and deletes
#   older matching `macos-facts-*` directories and `.tar.gz` archives.
#   Configure with INVENTORY_KEEP_RECENT (default: 3).

set -u
set -o pipefail
umask 077

FULL_DEFAULTS=0
COPY_CONFIGS=0
OUTDIR=""
KEEP_RECENT="${INVENTORY_KEEP_RECENT:-3}"

usage() {
  sed -n '1,30p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --full-defaults) FULL_DEFAULTS=1 ;;
  --copy-configs) COPY_CONFIGS=1 ;;
  -o)
    shift
    [ $# -gt 0 ] || {
      echo "Missing argument for -o" >&2
      exit 1
    }
    OUTDIR="$1"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage
    exit 1
    ;;
  esac
  shift
done

normalize_keep_recent() {
  case "${KEEP_RECENT}" in
    ''|*[!0-9]*)
      KEEP_RECENT=3
      ;;
  esac
}

prune_old_macos_snapshots() {
  local parent_dir="$1"
  local keep="$2"
  local snaps_tmp delete_tmp snap

  [ -d "$parent_dir" ] || return 0

  snaps_tmp="$(mktemp "${TMPDIR:-/tmp}/macinv.snaps.XXXXXX")" || return 0
  delete_tmp="$(mktemp "${TMPDIR:-/tmp}/macinv.delete.XXXXXX")" || {
    rm -f "$snaps_tmp"
    return 0
  }

  for snap in "$parent_dir"/macos-facts-*; do
    [ -e "$snap" ] || continue
    snap="$(basename "$snap")"
    case "$snap" in
      macos-facts-*.tar.gz)
        printf '%s\n' "${snap%.tar.gz}" >>"$snaps_tmp"
        ;;
      macos-facts-*)
        [ -d "$parent_dir/$snap" ] || continue
        printf '%s\n' "$snap" >>"$snaps_tmp"
        ;;
    esac
  done

  if [ ! -s "$snaps_tmp" ]; then
    rm -f "$snaps_tmp" "$delete_tmp"
    return 0
  fi

  sort -u "$snaps_tmp" >"$delete_tmp"
  count="$(wc -l <"$delete_tmp" | tr -d ' ')"
  if [ "$count" -le "$keep" ]; then
    rm -f "$snaps_tmp" "$delete_tmp"
    return 0
  fi

  prune_count=$((count - keep))
  head -n "$prune_count" "$delete_tmp" | while IFS= read -r old_snap; do
    [ -n "$old_snap" ] || continue
    rm -rf "$parent_dir/$old_snap"
    rm -f "$parent_dir/$old_snap.tar.gz"
  done

  rm -f "$snaps_tmp" "$delete_tmp"
}

normalize_keep_recent

timestamp="$(date '+%Y%m%d-%H%M%S')"
if [ -z "${OUTDIR}" ]; then
  OUTDIR="$PWD/macos-facts-$timestamp"
fi

mkdir -p "$OUTDIR"/{meta,system,network,security,power,brew,apps,defaults,configs,devtools,shell,launchd,packages}

have() {
  command -v "$1" >/dev/null 2>&1
}

safe_name() {
  # Replace anything sketchy for filenames
  echo "$1" | tr '/: ' '___' | tr -cd 'A-Za-z0-9._-'
}

run_cmd() {
  local name="$1"
  shift
  local outfile="$OUTDIR/${name}.txt"
  local rcfile="$OUTDIR/${name}.exitcode"
  mkdir -p "$(dirname "$outfile")"

  (
    printf "# CMD:"
    for arg in "$@"; do
      printf " %q" "$arg"
    done
    printf "\n\n"
    set +e
    "$@"
    rc=$?
    set -e
    printf "\n# EXIT_CODE: %s\n" "$rc"
    echo "$rc" >"$rcfile"
    exit 0
  ) >"$outfile" 2>&1
}

run_shell() {
  local name="$1"
  shift
  local cmd="$*"
  local outfile="$OUTDIR/${name}.txt"
  local rcfile="$OUTDIR/${name}.exitcode"
  mkdir -p "$(dirname "$outfile")"

  (
    printf "# CMD: bash -lc %q\n\n" "$cmd"
    set +e
    bash -lc "$cmd"
    rc=$?
    set -e
    printf "\n# EXIT_CODE: %s\n" "$rc"
    echo "$rc" >"$rcfile"
    exit 0
  ) >"$outfile" 2>&1
}

write_file() {
  local rel="$1"
  shift
  mkdir -p "$(dirname "$OUTDIR/$rel")"
  printf "%s\n" "$*" >"$OUTDIR/$rel"
}

dump_defaults_domain() {
  local domain="$1"
  local base
  base="$(safe_name "$domain")"
  local plist="$OUTDIR/defaults/${base}.plist"
  local txt="$OUTDIR/defaults/${base}.txt"
  local err="$OUTDIR/defaults/${base}.err"

  if [ "$domain" = "NSGlobalDomain" ]; then
    set +e
    defaults export -g - >"$plist" 2>"$err"
    rc=$?
    set -e
  else
    set +e
    defaults export "$domain" - >"$plist" 2>"$err"
    rc=$?
    set -e
  fi

  if [ "$rc" -eq 0 ] && [ -s "$plist" ]; then
    if have plutil; then
      plutil -convert xml1 "$plist" >/dev/null 2>&1 || true
    fi
    rm -f "$err"
  else
    rm -f "$plist"
    if [ "$domain" = "NSGlobalDomain" ]; then
      run_cmd "defaults/${base}" defaults read -g
    else
      run_cmd "defaults/${base}" defaults read "$domain"
    fi
    [ -s "$err" ] || rm -f "$err"
    [ -f "$txt" ] || true
  fi
}

copy_or_hash_config() {
  local src="$1"
  local rel="$2"
  if [ ! -e "$src" ]; then
    return 0
  fi

  if [ "$COPY_CONFIGS" -eq 1 ]; then
    mkdir -p "$(dirname "$OUTDIR/configs/$rel")"
    if [ -d "$src" ]; then
      # Avoid copying massive caches accidentally
      run_shell "configs/copy_$(safe_name "$rel")" "cp -R \"$src\" \"$OUTDIR/configs/$rel\""
    else
      cp "$src" "$OUTDIR/configs/$rel" 2>/dev/null || true
    fi
  else
    if [ -f "$src" ]; then
      shasum -a 256 "$src" >>"$OUTDIR/configs/config_hashes.txt" 2>/dev/null || true
    elif [ -d "$src" ]; then
      echo "DIR  $src" >>"$OUTDIR/configs/config_hashes.txt"
      run_shell "configs/hash_$(safe_name "$rel")" "find \"$src\" -type f 2>/dev/null | sort | while IFS= read -r f; do shasum -a 256 \"\$f\"; done"
    fi
  fi
}

# --- metadata ---
write_file "meta/collected_at_utc.txt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
write_file "meta/collector_user.txt" "${USER:-unknown}"
write_file "meta/flags.txt" "FULL_DEFAULTS=$FULL_DEFAULTS" "COPY_CONFIGS=$COPY_CONFIGS"
write_file "meta/review_before_sharing.txt" \
  "Review for sensitive data before sharing." \
  "This snapshot may include hostnames, local network details, installed software, and app preferences." \
  "If --copy-configs was used, config files may contain secrets/tokens."

# --- core system facts ---
run_cmd "system/sw_vers" sw_vers
run_cmd "system/uname" uname -a
run_cmd "system/hostname" hostname
run_cmd "system/id" id
run_cmd "system/groups" groups
run_cmd "system/who" who
run_cmd "system/date" date
run_cmd "system/sysctl_hw_model" sysctl hw.model
run_cmd "system/sysctl_machine" sysctl hw.machine
run_cmd "system/sysctl_cpu_brand" sysctl machdep.cpu.brand_string
run_cmd "system/scutil_ComputerName" scutil --get ComputerName
run_cmd "system/scutil_HostName" scutil --get HostName
run_cmd "system/scutil_LocalHostName" scutil --get LocalHostName
run_cmd "system/system_profiler_software_hardware" system_profiler -json SPSoftwareDataType SPHardwareDataType
run_cmd "system/system_profiler_storage_power" system_profiler -json SPStorageDataType SPPowerDataType
run_cmd "system/system_profiler_displays_audio" system_profiler -json SPDisplaysDataType SPAudioDataType
run_cmd "system/system_profiler_bluetooth_wifi" system_profiler -json SPBluetoothDataType SPAirPortDataType

# --- security / management ---
run_cmd "security/csrutil_status" csrutil status
run_cmd "security/spctl_status" spctl --status
run_cmd "security/fdesetup_status" fdesetup status
run_cmd "security/profiles_enrollment" profiles status -type enrollment
run_cmd "security/softwareupdate_history" softwareupdate --history
run_cmd "security/systemextensionsctl_list" systemextensionsctl list

# --- power / energy ---
run_cmd "power/pmset_custom" pmset -g custom
run_cmd "power/pmset_assertions" pmset -g assertions
run_cmd "power/pmset_batt" pmset -g batt
run_cmd "power/pmset_schedule" pmset -g sched

# --- network facts (review before sharing) ---
run_cmd "network/ifconfig" ifconfig
run_cmd "network/route_default" route -n get default
run_cmd "network/scutil_dns" scutil --dns
run_cmd "network/scutil_proxy" scutil --proxy
run_cmd "network/networksetup_hardwareports" networksetup -listallhardwareports
run_cmd "network/networksetup_services" networksetup -listallnetworkservices
run_cmd "network/networksetup_serviceorder" networksetup -listnetworkserviceorder

# --- shell / login / launchd ---
run_cmd "shell/echo_shell" bash -lc 'printf "%s\n" "$SHELL"'
run_cmd "shell/etc_shells" cat /etc/shells
run_cmd "shell/login_items_crontab" crontab -l
run_cmd "launchd/launchctl_list" launchctl list
run_shell "launchd/user_launchagents" 'ls -la "$HOME/Library/LaunchAgents" 2>/dev/null || true'
run_cmd "launchd/system_launchagents" ls -la /Library/LaunchAgents
run_cmd "launchd/system_launchdaemons" ls -la /Library/LaunchDaemons

# --- package receipts / apps ---
run_cmd "packages/pkgutil_pkgs" pkgutil --pkgs
run_shell "apps/application_bundles" 'find /Applications /System/Applications "$HOME/Applications" -maxdepth 3 -type d -name "*.app" 2>/dev/null | sort'
run_cmd "apps/ls_applications" ls -la /Applications
run_shell "apps/ls_user_applications" 'ls -la "$HOME/Applications" 2>/dev/null || true'
if have mas; then
  run_cmd "apps/mas_list" mas list
fi

# --- Homebrew ---
if have brew; then
  run_cmd "brew/version" brew --version
  run_cmd "brew/config" brew config
  run_cmd "brew/taps" brew tap
  run_cmd "brew/formulae_versions" brew list --formula --versions
  run_cmd "brew/casks_versions" brew list --cask --versions
  run_cmd "brew/leaves" brew leaves
  run_cmd "brew/services" brew services list
  run_cmd "brew/info_installed_json" brew info --json=v2 --installed

  {
    echo "# CMD: brew bundle dump --describe --force --file \"$OUTDIR/brew/Brewfile.snapshot\""
    set +e
    brew bundle dump --describe --force --file "$OUTDIR/brew/Brewfile.snapshot"
    rc=$?
    set -e
    echo
    echo "# EXIT_CODE: $rc"
  } >"$OUTDIR/brew/bundle_dump.txt" 2>&1
else
  write_file "brew/not_installed.txt" "Homebrew not found in PATH."
fi

# --- common dev tools / package managers ---
for tool in git ansible ansible-playbook python3 pip3 node npm pnpm yarn ruby gem go rustc cargo java code; do
  if have "$tool"; then
    run_cmd "devtools/${tool}_version" "$tool" --version
  fi
done

if have pip3; then
  run_cmd "devtools/pip3_freeze" pip3 freeze
fi
if have npm; then
  run_cmd "devtools/npm_global_ls" npm -g ls --depth=0
fi
if have gem; then
  run_cmd "devtools/gem_list" gem list
fi
if have cargo; then
  run_cmd "devtools/cargo_install_list" cargo install --list
fi
if have code; then
  run_cmd "devtools/vscode_extensions" code --list-extensions --show-versions
fi
if have ansible-config; then
  run_cmd "devtools/ansible_config_dump_only_changed" ansible-config dump --only-changed
fi
if have ansible-galaxy; then
  run_cmd "devtools/ansible_galaxy_collections" ansible-galaxy collection list
fi

# --- macOS defaults (targeted, then optional full export) ---
run_cmd "defaults/domains_list" defaults domains

TARGET_DOMAINS=(
  NSGlobalDomain
  com.apple.dock
  com.apple.finder
  com.apple.desktopservices
  com.apple.screencapture
  com.apple.spaces
  com.apple.symbolichotkeys
  com.apple.controlcenter
  com.apple.menuextra.clock
  com.apple.ActivityMonitor
  com.apple.Terminal
  com.apple.TextEdit
  com.apple.universalaccess
  com.apple.loginwindow
  com.apple.SoftwareUpdate
  com.apple.AppleMultitouchTrackpad
  com.apple.driver.AppleBluetoothMultitouch.trackpad
  com.apple.trackpad
)

for d in "${TARGET_DOMAINS[@]}"; do
  dump_defaults_domain "$d"
done

# Some common non-Apple app domains if present
for d in com.googlecode.iterm2 com.microsoft.VSCode com.knollsoft.Rectangle org.hammerspoon.Hammerspoon; do
  set +e
  defaults read "$d" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    dump_defaults_domain "$d"
  fi
done

if [ "$FULL_DEFAULTS" -eq 1 ]; then
  run_shell "defaults/all_domains_export_log" '
    defaults domains 2>/dev/null | tr "," "\n" | sed "s/^ *//; s/ *$//" | grep -v "^$" > "'"$OUTDIR"'/defaults/all_domains.txt"
  '
  if [ -f "$OUTDIR/defaults/all_domains.txt" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      dump_defaults_domain "$d"
    done <"$OUTDIR/defaults/all_domains.txt"
  fi
fi

# --- selected config files / hashes (user-level; review before sharing) ---
: >"$OUTDIR/configs/config_hashes.txt"

copy_or_hash_config "$HOME/.zshrc" ".zshrc"
copy_or_hash_config "$HOME/.zprofile" ".zprofile"
copy_or_hash_config "$HOME/.bash_profile" ".bash_profile"
copy_or_hash_config "$HOME/.gitconfig" ".gitconfig"
copy_or_hash_config "$HOME/.config/karabiner/karabiner.json" ".config/karabiner/karabiner.json"
copy_or_hash_config "$HOME/.hammerspoon/init.lua" ".hammerspoon/init.lua"
copy_or_hash_config "$HOME/.config/ghostty/config" ".config/ghostty/config"
copy_or_hash_config "$HOME/.config/alacritty/alacritty.toml" ".config/alacritty/alacritty.toml"
copy_or_hash_config "$HOME/.config/starship.toml" ".config/starship.toml"

# --- simple manifest ---
run_shell "meta/file_manifest" 'find "'"$OUTDIR"'" -type f | sed "s#^'"$OUTDIR"'#/SNAPSHOT#" | sort'

# --- archive ---
ARCHIVE="${OUTDIR%/}.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")"
prune_old_macos_snapshots "$(dirname "$OUTDIR")" "$KEEP_RECENT"

cat <<EOF

Snapshot complete.

Directory: $OUTDIR
Archive:    $ARCHIVE
Retention:  keeping newest $KEEP_RECENT macos-facts snapshots in $(dirname "$OUTDIR")

Recommended files to inspect first:
- $OUTDIR/meta/review_before_sharing.txt
- $OUTDIR/brew/Brewfile.snapshot
- $OUTDIR/brew/formulae_versions.txt
- $OUTDIR/brew/casks_versions.txt
- $OUTDIR/defaults/
- $OUTDIR/configs/config_hashes.txt (or copied configs if --copy-configs was used)

EOF
