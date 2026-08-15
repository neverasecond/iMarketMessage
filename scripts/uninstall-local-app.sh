#!/bin/bash
set -euo pipefail

app_path="${HOME}/Applications/iMM.app"
remove_data=0
assume_yes=0

usage() {
    cat <<'USAGE'
Usage: scripts/uninstall-local-app.sh [options]

Remove exactly one local iMM.app and stop its active per-user monitor. User
data is preserved by default.

Options:
  --app PATH          installed iMM.app (default: ~/Applications/iMM.app)
  --remove-data       also remove ~/Library/Application Support/MarketMessage
  --yes               do not ask for confirmation
  -h, --help          show this help

The API key remains in Keychain. Delete it from iMM.app before uninstalling,
or remove the iMarketMessage item manually in Keychain Access.
USAGE
}

while (($# > 0)); do
    case "$1" in
        --app)
            [[ -n "${2:-}" ]] || { echo "--app requires a path" >&2; exit 2; }
            app_path="$2"
            shift 2
            ;;
        --remove-data)
            remove_data=1
            shift
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
    *) echo "This uninstaller requires macOS." >&2; exit 1 ;;
esac

for tool in launchctl id; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

if [[ "$app_path" != /* ]]; then
    app_path="$(cd "$(dirname "$app_path")" && pwd -P)/$(basename "$app_path")"
fi
if [[ ! -d "$app_path" || "$(basename "$app_path")" != "iMM.app" || -L "$app_path" ]]; then
    echo "Target must be an existing, non-symlink iMM.app: $app_path" >&2
    exit 1
fi

data_dir="${HOME}/Library/Application Support/MarketMessage"
if (( assume_yes == 0 )); then
    echo "This will remove exactly: $app_path"
    echo "It will preserve: $data_dir"
    if (( remove_data == 1 )); then
        echo "It will also remove exactly: $data_dir"
    fi
    echo "If background monitoring is enabled, first use iMM.app's 停用 button to unregister SMAppService."
    printf 'Continue? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Cancelled."; exit 0 ;;
    esac
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
stop_agent com.imarketmessage.monitor
stop_agent com.imarketmessage.gateway

rm -rf -- "$app_path"
if (( remove_data == 1 )) && [[ -d "$data_dir" ]]; then
    case "$data_dir" in
        "${HOME}/Library/Application Support/MarketMessage") ;;
        *) echo "Refusing an unexpected data path: $data_dir" >&2; exit 1 ;;
    esac
    rm -rf -- "$data_dir"
    echo "Removed user data directory: $data_dir"
else
    echo "Preserved user data directory (if present): $data_dir"
fi

echo "Removed app: $app_path"
echo "Keychain credentials were not modified. If SMAppService still appears in Login Items, reopen the old app if available and choose 停用, then remove its Login Item entry."
