import AppKit
import SwiftUI

final class AgentOverviewViewModel: ObservableObject {
    @Published var overview = AgentOverviewSnapshot.initial()
    @Published var expandedKey: String?

    var onRefresh: (() -> Void)?
    var onToggleWatcher: (() -> Void)?
    var onOpenAgent: ((String) -> Void)?
    var onQuit: (() -> Void)?

    func refresh() { onRefresh?() }
    func toggleWatcher() { onToggleWatcher?() }
    func openAgent(_ key: String) { onOpenAgent?(key) }
    func quit() { onQuit?() }
}

private enum AgentOverviewFocusTarget: Hashable {
    case agent(String)
    case openAgent(String)
    case refresh
    case watcher
    case quit
}

struct AgentOverviewPanel: View {
    @ObservedObject var model: AgentOverviewViewModel
    @FocusState private var focusedTarget: AgentOverviewFocusTarget?

    private var orderedAgents: [AgentSignalSnapshot] {
        let source = model.overview.status.agents
        let originalOrder = Dictionary(uniqueKeysWithValues: source.enumerated().map { ($0.element.definition.key, $0.offset) })
        return source.sorted { left, right in
            let leftRank = rank(left)
            let rightRank = rank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            return originalOrder[left.definition.key, default: 0] < originalOrder[right.definition.key, default: 0]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.38)
            LazyVStack(spacing: 1) {
                ForEach(orderedAgents, id: \.definition.key) { agent in
                    AgentOverviewRow(
                        agent: agent,
                        usage: model.overview.usageByKey[agent.definition.shortLabel],
                        usageRefreshing: model.overview.usageRefreshing,
                        spinnerAngle: model.overview.spinnerAngle,
                        isExpanded: model.expandedKey == agent.definition.key,
                        focusedTarget: $focusedTarget,
                        onToggle: {
                            withAnimation(.easeOut(duration: 0.16)) {
                                model.expandedKey = model.expandedKey == agent.definition.key
                                    ? nil
                                    : agent.definition.key
                            }
                        },
                        onOpen: { model.openAgent(agent.definition.key) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .focusSection()
            Divider().opacity(0.42)
            footer
        }
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Agent 总览")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 4)
            chip("\(model.overview.status.agents.count) Agent", color: .secondary)
            let working = model.overview.status.agents.filter { $0.state == .working }.count
            let awaiting = model.overview.status.agents.filter { $0.state == .awaiting }.count
            let alerts = model.overview.usageByKey.values.filter(\.summaryHasAlert).count
            if working > 0 { chip("\(working) 任务中", color: OverviewPalette.idle) }
            if awaiting > 0 { chip("\(awaiting) 待人工", color: OverviewPalette.awaiting) }
            if alerts > 0 { chip("\(alerts) 告警", color: OverviewPalette.offline) }
            if model.overview.usageError != nil { chip("用量读取失败", color: OverviewPalette.offline) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: model.refresh) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(model.overview.usageRefreshing ? 360 : 0))
                        .animation(
                            model.overview.usageRefreshing
                                ? .linear(duration: 0.85).repeatForever(autoreverses: false)
                                : .default,
                            value: model.overview.usageRefreshing
                        )
                    Text(model.overview.usageRefreshing ? "刷新中" : "立即刷新")
                    Text("⌘R").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(model.overview.usageRefreshing ? "正在刷新 Agent 状态和额度" : "立即刷新 Agent 状态和额度")
            .accessibilityHint("键盘快捷键 Command R")
            .focusable()
            .focused($focusedTarget, equals: .refresh)

            if let checkedAt = model.overview.usageByKey.values.map(\.checkedAt).max() {
                Text("用量 \(clock(checkedAt))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 2)

            Toggle(
                "随 Agent 启动",
                isOn: Binding(
                    get: { model.overview.watcherEnabled },
                    set: { _ in model.toggleWatcher() }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .accessibilityLabel("随 Agent 启动")
            .accessibilityValue(AgentOverviewAccessibility.watcherValue(enabled: model.overview.watcherEnabled))
            .accessibilityHint("切换后决定是否随受支持的 Agent 启动")
            .focusable()
            .focused($focusedTarget, equals: .watcher)

            Button(action: model.quit) {
                HStack(spacing: 3) {
                    Text("退出")
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("退出 Agent Overview")
            .accessibilityHint("键盘快捷键 Command Q")
            .focusable()
            .focused($focusedTarget, equals: .quit)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .focusSection()
    }

    private func rank(_ agent: AgentSignalSnapshot) -> Int {
        let statusRank: Int
        switch agent.state {
        case .awaiting: statusRank = 0
        case .working: statusRank = 1
        case .completed: statusRank = 3
        case .idle: statusRank = 4
        case .unknown: statusRank = 5
        case .offline: statusRank = 6
        case .error: statusRank = 2
        }
        if model.overview.usageByKey[agent.definition.shortLabel]?.summaryHasAlert == true {
            return min(statusRank, 2)
        }
        return statusRank
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct AgentOverviewRow: View {
    private static let quotaColumnWidth: CGFloat = 88

    let agent: AgentSignalSnapshot
    let usage: AgentUsageSnapshot?
    let usageRefreshing: Bool
    let spinnerAngle: CGFloat
    let isExpanded: Bool
    let focusedTarget: FocusState<AgentOverviewFocusTarget?>.Binding
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 9) {
                    identityBadge
                    identity
                    Spacer(minLength: 2)
                    status
                    if usage?.summaryHasExhaustedWindow == true {
                        tag("额度耗尽", foreground: .white, background: OverviewPalette.offline)
                    } else if usage?.isStale == true {
                        tag(staleShortText, foreground: .secondary, background: Color(nsColor: .controlBackgroundColor))
                    }
                    quotaSummary
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 7)
                .frame(minHeight: 39)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentOverviewAccessibility.rowLabel(for: agent))
            .accessibilityValue(
                AgentOverviewAccessibility.rowValue(
                    for: agent,
                    usage: usage,
                    usageRefreshing: usageRefreshing,
                    isExpanded: isExpanded
                )
            )
            .accessibilityHint(AgentOverviewAccessibility.rowHint(isExpanded: isExpanded))
            .focusable()
            .focused(focusedTarget, equals: .agent(agent.definition.key))

            if isExpanded {
                detail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(usage?.summaryHasExhaustedWindow == true ? OverviewPalette.offline.opacity(0.065) : Color.clear)
        )
    }

    private var identityBadge: some View {
        Text(agent.definition.shortLabel)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 27, height: 27)
            .background(OverviewPalette.brand(agent.definition.shortLabel), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(agent.definition.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text(agent.definition.entryKind.rawValue)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                )
        }
        .frame(width: 105, alignment: .leading)
    }

    private var status: some View {
        HStack(spacing: 4) {
            AgentStateLamp(state: agent.state, spinnerAngle: spinnerAngle)
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text(agent.state.chineseLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OverviewPalette.statusText(agent.state))
                .lineLimit(1)
        }
        .frame(width: 68, alignment: .leading)
    }

    @ViewBuilder
    private var quotaSummary: some View {
        if let window = usage?.summaryWindow {
            HStack(spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(nsColor: .separatorColor).opacity(0.28))
                        Capsule()
                            .fill(quotaColor(window.remainingPercent))
                            .frame(width: max(2, geometry.size.width * window.remainingPercent / 100))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(window.label)
                    .accessibilityValue(
                        "\(window.approximate ? "约 " : "")剩余 \(formatPercent(window.remainingPercent))%，\(resetText(window.resetsAt))"
                    )
                }
                .frame(width: 52, height: 5)
                Text("\(Int(window.remainingPercent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(window.remainingPercent < 20 && usage?.isStale != true ? OverviewPalette.offline : .primary)
                    .frame(width: 31, alignment: .trailing)
            }
            .frame(width: Self.quotaColumnWidth, alignment: .trailing)
        } else {
            Text(emptyQuotaText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: Self.quotaColumnWidth, alignment: .trailing)
        }
    }

    private var emptyQuotaText: String {
        if usage?.error != nil { return "!" }
        if ["hm", "oc"].contains(agent.definition.shortLabel) { return "—" }
        if agent.ready && usageRefreshing { return "…" }
        return agent.ready ? "待同步" : "—"
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let usage, !usage.windows.isEmpty {
                ForEach(usage.windows) { window in
                    HStack(spacing: 7) {
                        Text(window.label)
                            .font(.system(size: 10.5))
                            .frame(width: 88, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(nsColor: .separatorColor).opacity(0.28))
                                Capsule()
                                    .fill(quotaColor(window.remainingPercent))
                                    .frame(width: max(2, geometry.size.width * window.remainingPercent / 100))
                            }
                        }
                        .frame(width: 64, height: 5)
                        Text("\(window.approximate ? "约 " : "")剩余 \(formatPercent(window.remainingPercent))%")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(window.remainingPercent < 20 && !usage.isStale ? OverviewPalette.offline : .secondary)
                        Spacer(minLength: 2)
                        Text(resetText(window.resetsAt))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text(detailEmptyText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if let plan = usage?.plan { Text("套餐 \(plan)") }
                if let usage, usage.isStale { Text(staleDetailText).foregroundStyle(Color(red: 0.69, green: 0.47, blue: 0)) }
                if let checkedAt = usage?.checkedAt { Text("检查 \(clock(checkedAt))") }
                if let error = usage?.error { Text("读取失败：\(error)").lineLimit(1) }
                Spacer(minLength: 4)
                Button("打开 \(agent.definition.title)", action: onOpen)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("打开 \(agent.definition.title)")
                    .accessibilityHint("在对应应用或网页中打开")
                    .focusable()
                    .focused(focusedTarget, equals: .openAgent(agent.definition.key))
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
        .padding(.leading, 42)
        .padding(.trailing, 10)
        .padding(.bottom, 9)
    }

    private var detailEmptyText: String {
        if let error = usage?.error { return "额度读取失败：\(error)" }
        if agent.definition.shortLabel == "hm" || agent.definition.shortLabel == "oc" {
            return "该平台无额度接口，仅显示运行状态。"
        }
        if agent.state == .offline { return "Agent 未开启，已暂停额度刷新。" }
        return "正在读取额度…"
    }

    private func tag(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }

    private func quotaColor(_ remaining: Double) -> Color {
        if usage?.isStale == true { return Color(nsColor: .systemGray) }
        if remaining >= 50 { return OverviewPalette.idle }
        if remaining >= 20 { return Color(nsColor: .systemOrange) }
        return OverviewPalette.offline
    }

    private var staleShortText: String {
        guard let date = usage?.sourceUpdatedAt else { return "数据过期" }
        let hours = max(1, Int(Date().timeIntervalSince(date) / 3600))
        return "数据 \(hours)h 前"
    }

    private var staleDetailText: String {
        guard let date = usage?.sourceUpdatedAt else { return "⚠ 额度数据已过期" }
        let hours = max(1, Int(Date().timeIntervalSince(date) / 3600))
        return "⚠ 额度数据 \(clock(date)) · 已过期 \(hours) 小时"
    }

    private func formatPercent(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.005 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "重置 —" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return "重置 \(formatter.string(from: date))"
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct AgentStateLamp: View {
    let state: AgentSignalState
    let spinnerAngle: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state == .working {
                Circle()
                    .fill(OverviewPalette.idle)
                    .opacity(workingOpacity)
            } else {
                Circle().fill(OverviewPalette.state(state))
            }
        }
    }

    private var workingOpacity: Double {
        guard !reduceMotion else { return 1 }
        let phase = (Foundation.cos(Double(spinnerAngle)) + 1) / 2
        return 0.2 + 0.8 * phase
    }
}

enum OverviewPalette {
    static let idle = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let completed = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let awaiting = Color(red: 0.902, green: 0.655, blue: 0)
    static let offline = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let unknown = Color(red: 0.557, green: 0.557, blue: 0.576)

    static func state(_ state: AgentSignalState) -> Color {
        switch state {
        case .idle, .working: return idle
        case .completed: return completed
        case .awaiting: return awaiting
        case .offline, .error: return offline
        case .unknown: return unknown
        }
    }

    static func statusText(_ state: AgentSignalState) -> Color {
        switch state {
        case .working: return idle
        case .awaiting: return awaiting
        case .offline, .error: return offline
        case .unknown: return unknown
        case .idle, .completed: return .primary
        }
    }

    static func brand(_ shortLabel: String) -> Color {
        switch shortLabel {
        case "cc": return Color(red: 0.851, green: 0.467, blue: 0.341)
        case "cdx": return Color(red: 0, green: 0.651, blue: 0.494)
        case "km": return Color(red: 0.231, green: 0.357, blue: 0.992)
        case "cs": return Color(red: 0.431, green: 0.337, blue: 0.812)
        case "hm": return Color(red: 0.627, green: 0.369, blue: 0.710)
        case "oc": return Color(red: 0.878, green: 0.514, blue: 0.180)
        default: return .gray
        }
    }
}
