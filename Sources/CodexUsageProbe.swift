import Darwin
import Foundation

struct ProbeUsageWindow: Codable, Equatable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetsAt: Date?
    let approximate: Bool
}

struct ProbeAgentUsage: Codable, Equatable {
    let key: String
    let plan: String?
    let windows: [ProbeUsageWindow]
    let sourceUpdatedAt: Date?
    let checkedAt: Date
    let sourcePath: String?
    let note: String?
    let error: String?
}

struct ProbePayload: Codable, Equatable {
    let fetchedAt: Date
    let agents: [ProbeAgentUsage]
}

enum CodexProbeError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case serverError(String)
    case invalidResponse
    case noLimits

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex executable was not found"
        case .launchFailed(let message):
            return "Could not launch Codex: \(message)"
        case .timedOut:
            return "Codex usage request timed out"
        case .serverError(let message):
            return "Codex returned an error: \(message)"
        case .invalidResponse:
            return "Codex returned an unrecognized response"
        case .noLimits:
            return "No displayable Codex rate limits were returned"
        }
    }
}

enum CodexRateLimitParser {
    static func parse(result: [String: Any], sourcePath: String, now: Date = Date()) throws -> ProbeAgentUsage {
        guard let fallback = result["rateLimits"] as? [String: Any] else {
            throw CodexProbeError.invalidResponse
        }

        var limits: [(id: String, name: String, windows: [ProbeUsageWindow])] = []
        if let values = result["rateLimitsByLimitId"] as? [String: Any] {
            for (id, rawValue) in values {
                guard let value = rawValue as? [String: Any] else { continue }
                limits.append(parseLimit(value, fallbackID: id))
            }
        }
        if limits.isEmpty {
            limits.append(parseLimit(fallback, fallbackID: fallback["limitId"] as? String ?? "codex"))
        }

        limits.sort { left, right in
            if left.id == "codex" { return true }
            if right.id == "codex" { return false }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }

        let windows = limits.flatMap { limit in
            limit.windows.map { window in
                ProbeUsageWindow(
                    label: limit.id == "codex" ? window.label : "\(limit.name) · \(window.label)",
                    usedPercent: window.usedPercent,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    approximate: false
                )
            }
        }
        guard !windows.isEmpty else { throw CodexProbeError.noLimits }

        let credits = result["rateLimitResetCredits"] as? [String: Any]
        let available = number(credits?["availableCount"])?.intValue
        let note = available.flatMap { $0 > 0 ? "Full reset ×\($0)" : nil }

        return ProbeAgentUsage(
            key: "cdx",
            plan: fallback["planType"] as? String,
            windows: windows,
            sourceUpdatedAt: now,
            checkedAt: now,
            sourcePath: sourcePath,
            note: note,
            error: nil
        )
    }

    private static func parseLimit(
        _ value: [String: Any],
        fallbackID: String
    ) -> (id: String, name: String, windows: [ProbeUsageWindow]) {
        let id = value["limitId"] as? String ?? fallbackID
        let rawName = (value["limitName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName?.isEmpty == false ? rawName! : (id == "codex" ? "Codex" : id)
        let windows = [value["primary"], value["secondary"]].compactMap(parseWindow)
        return (id, name, windows)
    }

    private static func parseWindow(_ rawValue: Any?) -> ProbeUsageWindow? {
        guard
            let value = rawValue as? [String: Any],
            let used = number(value["usedPercent"])?.doubleValue
        else { return nil }

        let duration = number(value["windowDurationMins"])?.intValue
        let reset = number(value["resetsAt"]).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return ProbeUsageWindow(
            label: durationLabel(duration),
            usedPercent: used,
            remainingPercent: max(0, min(100, 100 - used)),
            resetsAt: reset,
            approximate: false
        )
    }

    private static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Rate-limit window" }
        if minutes == 300 { return "5-hour window" }
        if minutes == 10_080 { return "1-week window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let value = value as? NSNumber { return value }
        if let text = value as? String, let value = Double(text) { return NSNumber(value: value) }
        return nil
    }
}

final class CodexUsageProbe {
    private let executableCandidates: [String]

    init(executableCandidates: [String] = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]) {
        self.executableCandidates = executableCandidates
    }

    func fetch() -> ProbeAgentUsage {
        let now = Date()
        do {
            return try fetchSynchronously(now: now)
        } catch {
            return ProbeAgentUsage(
                key: "cdx",
                plan: nil,
                windows: [],
                sourceUpdatedAt: nil,
                checkedAt: now,
                sourcePath: nil,
                note: nil,
                error: error.localizedDescription
            )
        }
    }

    private func fetchSynchronously(now: Date) throws -> ProbeAgentUsage {
        guard let executable = executableCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexProbeError.executableNotFound
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do { try process.run() } catch {
            throw CodexProbeError.launchFailed(error.localizedDescription)
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            for _ in 0..<20 where process.isRunning { usleep(50_000) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }

        let requests: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "agent-overview-macos",
                        "title": "Agent Overview",
                        "version": "0.1.0",
                    ],
                    "capabilities": NSNull(),
                ],
            ],
            ["method": "initialized"],
            ["id": 2, "method": "account/rateLimits/read"],
        ]
        for request in requests {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(20)
        var buffer = Data()
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, 500)
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexProbeError.invalidResponse
            }
            if result == 0 { continue }
            if pollDescriptor.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 8_192)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count <= 0 { break }
                buffer.append(contentsOf: bytes.prefix(count))

                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard
                        !line.isEmpty,
                        let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                        (object["id"] as? NSNumber)?.intValue == 2
                    else { continue }
                    if let serverError = object["error"] as? [String: Any] {
                        throw CodexProbeError.serverError(serverError["message"] as? String ?? "Unknown error")
                    }
                    guard let payload = object["result"] as? [String: Any] else {
                        throw CodexProbeError.invalidResponse
                    }
                    return try CodexRateLimitParser.parse(result: payload, sourcePath: executable, now: now)
                }
            }
            if pollDescriptor.revents & Int16(POLLHUP) != 0 { break }
        }
        throw CodexProbeError.timedOut
    }
}

#if AGENT_USAGE_PROBE_MAIN
@main
struct AgentUsageProbeMain {
    static func main() {
        let requested = Set(
            CommandLine.arguments
                .first(where: { $0.hasPrefix("--active=") })?
                .dropFirst("--active=".count)
                .split(separator: ",")
                .map(String.init) ?? ["cdx"]
        )
        let payload = ProbePayload(
            fetchedAt: Date(),
            agents: requested.contains("cdx") ? [CodexUsageProbe().fetch()] : []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            FileHandle.standardOutput.write(try encoder.encode(payload))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("Could not encode usage response\n", stderr)
            exit(1)
        }
    }
}
#endif
