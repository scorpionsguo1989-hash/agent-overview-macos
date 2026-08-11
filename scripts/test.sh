#!/bin/zsh
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=${TMPDIR:-/tmp}/AgentOverviewTests
swift_target="$(uname -m)-apple-macos13.0"
mkdir -p "$test_dir"

xcrun swiftc -swift-version 5 -target "$swift_target" \
  "$project_dir/Sources/AgentStatusModel.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Tests/UsageModelsTests.swift" \
  -o "$test_dir/usage-model-tests"
"$test_dir/usage-model-tests"

xcrun swiftc -swift-version 5 -target "$swift_target" \
  "$project_dir/Sources/AgentStatusModel.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/OverviewAccessibility.swift" \
  "$project_dir/Tests/OverviewAccessibilityTests.swift" \
  -o "$test_dir/overview-accessibility-tests"
"$test_dir/overview-accessibility-tests"

xcrun swiftc -swift-version 5 -target "$swift_target" \
  "$project_dir/Sources/AgentStatusModel.swift" \
  "$project_dir/Sources/StatusProvider.swift" \
  "$project_dir/Tests/StatusModelTests.swift" \
  -o "$test_dir/status-model-tests"
"$test_dir/status-model-tests"

xcrun swiftc -swift-version 5 -target "$swift_target" \
  "$project_dir/Sources/CodexUsageProbe.swift" \
  "$project_dir/Tests/CodexUsageProbeTests.swift" \
  -o "$test_dir/codex-usage-tests"
"$test_dir/codex-usage-tests"

xcrun swiftc -swift-version 5 -target "$swift_target" -framework AppKit \
  "$project_dir/Sources/AgentStatusModel.swift" \
  "$project_dir/Sources/SignalRenderer.swift" \
  "$project_dir/Tests/RendererSmoke.swift" \
  -o "$test_dir/renderer-smoke"
"$test_dir/renderer-smoke" "$test_dir/identity-badges.png"
test -s "$test_dir/identity-badges.png"

xcrun swiftc -swift-version 5 -target "$swift_target" -framework AppKit -framework SwiftUI \
  "$project_dir/Sources/AgentStatusModel.swift" \
  "$project_dir/Sources/UsageModels.swift" \
  "$project_dir/Sources/OverviewAccessibility.swift" \
  "$project_dir/Sources/OverviewPanel.swift" \
  "$project_dir/Tests/OverviewRenderSmoke.swift" \
  -o "$test_dir/overview-render-smoke"
"$test_dir/overview-render-smoke" "$test_dir/overview-panel.png"
test -s "$test_dir/overview-panel.png"

echo "Agent Overview test suite: PASS"
