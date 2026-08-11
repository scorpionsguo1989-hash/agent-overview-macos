#!/bin/zsh
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
app_name="Agent Overview"
output_dir=${AGENT_OVERVIEW_OUTPUT_DIR:-${TMPDIR:-/tmp}/AgentOverviewBuild}
bundle="$output_dir/$app_name.app"
contents="$bundle/Contents"
swift_target="$(uname -m)-apple-macos13.0"

rm -rf "$bundle"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources"
cp "$project_dir/Resources/Info.plist" "$contents/Info.plist"
plutil -lint "$contents/Info.plist"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -target "$swift_target" \
  -framework AppKit \
  -framework ServiceManagement \
  -framework SwiftUI \
  -framework UserNotifications \
  "$project_dir/Sources/AgentStatusModel.swift" \
  "$project_dir/Sources/StatusProvider.swift" \
  "$project_dir/Sources/SignalRenderer.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/UsageProvider.swift" \
  "$project_dir/Sources/OverviewPanel.swift" \
  "$project_dir/Sources/main.swift" \
  -o "$contents/MacOS/$app_name"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -D AGENT_USAGE_PROBE_MAIN \
  -target "$swift_target" \
  "$project_dir/Sources/CodexUsageProbe.swift" \
  -o "$contents/Helpers/AgentUsageProbe"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -target "$swift_target" \
  -framework AppKit \
  "$project_dir/Sources/AgentLaunchWatcher.swift" \
  -o "$contents/Helpers/AgentSignalWatcher"

xattr -cr "$bundle"
codesign --force --sign - --timestamp=none "$contents/Helpers/AgentSignalWatcher"
codesign --force --sign - --timestamp=none "$contents/Helpers/AgentUsageProbe"
codesign --force --sign - --timestamp=none "$bundle"
codesign --verify --deep --strict "$bundle"

echo "$bundle"
