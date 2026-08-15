#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
source_app="$repo_dir/dist/iMM.app"
destination_dir="${HOME}/Applications"
assume_yes=0

usage() {
    cat <<'USAGE'
Usage: scripts/install-local-app.sh [--app PATH] [--destination DIR] [--yes]

Install the locally built iMM.app. The default target is
~/Applications/iMM.app. Existing Application Support data is preserved. Before
an upgrade, unregister both bundled SMAppService entries in the old app UI in
this order: gateway companion, then background monitor.
USAGE
}

while (($# > 0)); do
    case "$1" in
        --app)
            [[ -n "${2:-}" ]] || { echo "--app requires a path" >&2; exit 2; }
            source_app="$2"
            shift 2
            ;;
        --destination)
            [[ -n "${2:-}" ]] || { echo "--destination requires a directory" >&2; exit 2; }
            destination_dir="$2"
            shift 2
            ;;
        --yes)
            assume_yes=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$(uname -s)" in
    Darwin) ;;
    *) echo "This installer requires macOS." >&2; exit 1 ;;
esac

for tool in ditto plutil codesign launchctl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

if [[ "$source_app" != /* ]]; then
    source_app="$(cd "$(dirname "$source_app")" && pwd -P)/$(basename "$source_app")"
fi
if [[ ! -d "$source_app" || "$(basename "$source_app")" != "iMM.app" || -L "$source_app" ]]; then
    echo "Source must be an existing, non-symlink iMM.app: $source_app" >&2
    exit 1
fi

if [[ ! -d "$destination_dir" ]]; then
    mkdir -p -- "$destination_dir"
fi
destination_dir="$(cd "$destination_dir" && pwd -P)"
case "$destination_dir" in
    /|/System|/System/*|/Library|/Library/*)
        echo "Refusing unsafe destination directory: $destination_dir" >&2
        exit 1
        ;;
esac

target_app="$destination_dir/iMM.app"
if [[ -e "$target_app" && ! -d "$target_app" || -L "$target_app" ]]; then
    echo "Refusing a non-directory or symlink target: $target_app" >&2
    exit 1
fi
if [[ "$source_app" == "$target_app" ]]; then
    echo "Source and destination are the same app; nothing to install."
    exit 0
fi

plutil -lint "$source_app/Contents/Info.plist" \
    "$source_app/Contents/Library/LaunchAgents/com.imarketmessage.monitor.plist" \
    "$source_app/Contents/Library/LaunchAgents/com.imarketmessage.gateway.plist"
codesign --verify --deep --strict --verbose=2 "$source_app"

if [[ -e "$target_app" ]]; then
    echo "This will replace exactly: $target_app"
    echo "Application Support data is preserved: ${HOME}/Library/Application Support/MarketMessage"
    if (( assume_yes == 0 )); then
        printf 'Continue with the app replacement? [y/N] '
        read -r answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) echo "Cancelled."; exit 0 ;;
        esac
    fi
fi

uid="$(id -u)"
stop_agent() {
    local label="$1"
    local agent_target="gui/${uid}/${label}"
    if launchctl print "$agent_target" >/dev/null 2>&1; then
        echo "Stopping registered service: $agent_target"
        launchctl bootout "gui/${uid}/${label}"
    fi
}
# Stop the sender first so no new message is consumed while the monitor is
# still able to produce outbox files. This is only a launchctl fallback;
# SMAppService.unregister() must still be done in the old app UI.
stop_agent com.imarketmessage.gateway
stop_agent com.imarketmessage.monitor

staging_dir="$(mktemp -d "$destination_dir/.imarketmessage-install.XXXXXX")"
backup_app="$staging_dir/previous-iMM.app"
staged_app="$staging_dir/iMM.app"
cleanup() { rm -rf -- "$staging_dir"; }
trap cleanup EXIT

ditto "$source_app" "$staged_app"
plutil -lint "$staged_app/Contents/Info.plist" \
    "$staged_app/Contents/Library/LaunchAgents/com.imarketmessage.monitor.plist" \
    "$staged_app/Contents/Library/LaunchAgents/com.imarketmessage.gateway.plist"
codesign --verify --deep --strict --verbose=2 "$staged_app"

if [[ -e "$target_app" ]]; then
    mv -- "$target_app" "$backup_app"
fi
if ! mv -- "$staged_app" "$target_app"; then
    [[ -e "$backup_app" ]] && mv -- "$backup_app" "$target_app"
    echo "Unable to move the staged app into place; the previous app was restored when possible." >&2
    exit 1
fi
rm -rf -- "$backup_app"

echo "Installed local app: $target_app"
echo "No LaunchAgent was registered by this script. SMAppService registrations were not changed by this script."
echo "If desired, open iMM.app and restore services in this order: monitor, then gateway companion; approve each Login Item."
echo "User data remains at: ${HOME}/Library/Application Support/MarketMessage"
