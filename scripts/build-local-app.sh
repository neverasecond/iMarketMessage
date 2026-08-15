#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
output_dir="$repo_dir/dist"

if [[ "${1:-}" == "--output" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "--output requires a directory" >&2
        exit 2
    fi
    output_dir="$2"
elif [[ $# -ne 0 ]]; then
    echo "Usage: scripts/build-local-app.sh [--output DIRECTORY]" >&2
    exit 2
fi

case "$(uname -s)" in
    Darwin) ;;
    *) echo "This builder requires macOS." >&2; exit 1 ;;
esac

for tool in swift xcodebuild plutil codesign ditto; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Missing required tool: $tool" >&2
        exit 1
    fi
done

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" != *Xcode.app/Contents/Developer ]]; then
    echo "A full Xcode installation must be selected; CommandLineTools alone is not supported." >&2
    exit 1
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app_dir="$output_dir/iMM.app"
zip_path="$output_dir/iMM-v0.2.0-beta-local.zip"

case "$app_dir" in
    /|/Applications|/System|/Library|/Users|"$repo_dir")
        echo "Refusing unsafe output path: $app_dir" >&2
        exit 1
        ;;
    */iMM.app) ;;
    *) echo "Unexpected app output path" >&2; exit 1 ;;
esac

scratch_dir="$(mktemp -d /tmp/imarketmessage-v020-build.XXXXXX)"
module_cache="$scratch_dir/module-cache"
mkdir -m 700 "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
cleanup() {
    rm -rf -- "$scratch_dir"
}
trap cleanup EXIT

swift_build() {
    if [[ "${IMM_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
        swift build --disable-sandbox "$@"
    else
        swift build "$@"
    fi
}

cd "$repo_dir"
swift_build -c release --scratch-path "$scratch_dir" --product iMM
swift_build -c release --scratch-path "$scratch_dir" --product market-message-cli
bin_dir="$(swift_build -c release --scratch-path "$scratch_dir" --show-bin-path)"

rm -rf -- "$app_dir"
rm -f -- "$zip_path"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Library/LaunchAgents" "$app_dir/Contents/Resources"
install -m 755 "$bin_dir/iMM" "$app_dir/Contents/MacOS/iMM"
install -m 755 "$bin_dir/market-message-cli" "$app_dir/Contents/MacOS/market-message-cli"
install -m 644 "$repo_dir/Packaging/Info.plist" "$app_dir/Contents/Info.plist"
install -m 644 "$repo_dir/Packaging/com.imarketmessage.monitor.plist" "$app_dir/Contents/Library/LaunchAgents/com.imarketmessage.monitor.plist"

plutil -lint "$app_dir/Contents/Info.plist" "$app_dir/Contents/Library/LaunchAgents/com.imarketmessage.monitor.plist"
codesign --force --sign - --identifier com.imarketmessage.cli "$app_dir/Contents/MacOS/market-message-cli"
codesign --force --sign - --identifier com.imarketmessage.app "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
ditto -c -k --keepParent "$app_dir" "$zip_path"

echo "Built local ad-hoc signed app: $app_dir"
echo "Built local ZIP: $zip_path"
echo "This build is not Developer ID signed or notarized. Build it only from source you trust."
