import Darwin
import Foundation

final class AgentUsageProvider {
    // The public build intentionally ships only the Codex adapter. Other
    // providers would require reading private browser/app credentials.
    private static let quotaKeys = Set(["cdx"])

    private let workerQueue = DispatchQueue(label: "com.local.agent-overview.usage", qos: .utility)
    private let lock = NSLock()
    private let cacheURL: URL
    private var cachedByKey: [String: AgentUsageSnapshot] = [:]
    private var refreshing = false
    private var pendingCompletions: [([String: AgentUsageSnapshot], String?) -> Void] = []

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        cachedByKey = Self.loadCache(from: self.cacheURL)
    }

    func current() -> [String: AgentUsageSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return cachedByKey
    }

    func refresh(
        activeKeys: Set<String>,
        completion: @escaping ([String: AgentUsageSnapshot], String?) -> Void
    ) {
        lock.lock()
        pendingCompletions.append(completion)
        if refreshing {
            lock.unlock()
            return
        }
        refreshing = true
        lock.unlock()

        workerQueue.async { [weak self] in
            guard let self else { return }
            let result = self.runProbe(activeKeys: activeKeys)

            self.lock.lock()
            switch result {
            case .success(let payload):
                for incoming in payload.agents {
                    if incoming.error == nil, !incoming.windows.isEmpty {
                        self.cachedByKey[incoming.key] = incoming
                    } else if let existing = self.cachedByKey[incoming.key] {
                        self.cachedByKey[incoming.key] = existing.mergingError(from: incoming)
                    } else {
                        self.cachedByKey[incoming.key] = incoming
                    }
                }
                self.persistCacheLocked()
            case .failure:
                break
            }
            let cached = self.cachedByKey
            self.refreshing = false
            let completions = self.pendingCompletions
            self.pendingCompletions.removeAll()
            self.lock.unlock()

            let errorMessage: String?
            switch result {
            case .success: errorMessage = nil
            case .failure(let error): errorMessage = error.localizedDescription
            }
            DispatchQueue.main.async {
                completions.forEach { $0(cached, errorMessage) }
            }
        }
    }

    private func runProbe(activeKeys: Set<String>) -> Result<AgentUsagePayload, Error> {
        Result {
            let helperURL: URL
            if let overridePath = ProcessInfo.processInfo.environment["AGENT_OVERVIEW_USAGE_PROBE"],
               !overridePath.isEmpty {
                helperURL = URL(fileURLWithPath: overridePath)
            } else {
                helperURL = Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Helpers/AgentUsageProbe")
            }
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                throw ProbeError.helperMissing
            }

            let requested = activeKeys.intersection(Self.quotaKeys).sorted()
            guard !requested.isEmpty else {
                return AgentUsagePayload(fetchedAt: Date(), agents: [])
            }

            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = helperURL
            process.arguments = ["--active=\(requested.joined(separator: ","))"]
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            do {
                try process.run()
            } catch {
                throw ProbeError.launchFailed(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(42)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                for _ in 0..<20 where process.isRunning { usleep(50_000) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                throw ProbeError.timedOut
            }

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw ProbeError.failed(message.isEmpty ? "用量探针返回 \(process.terminationStatus)" : message)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            do {
                return try decoder.decode(AgentUsagePayload.self, from: output)
            } catch {
                throw ProbeError.invalidResponse
            }
        }
    }

    private func persistCacheLocked() {
        let payload = AgentUsagePayload(
            fetchedAt: Date(),
            agents: cachedByKey.values.sorted { $0.key < $1.key }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(payload) else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheURL.path
            )
        } catch {
            // The live result remains available in memory; a cache write must never block usage display.
        }
    }

    private static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentOverview", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    private static func loadCache(from url: URL) -> [String: AgentUsageSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let payload = try? decoder.decode(AgentUsagePayload.self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: payload.agents
            .filter { quotaKeys.contains($0.key) }
            .map { ($0.key, $0) })
    }
}

private enum ProbeError: LocalizedError {
    case helperMissing
    case launchFailed(String)
    case timedOut
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .helperMissing: return "Agent 用量探针缺失，请重新安装 Agent 总览"
        case .launchFailed(let message): return "Agent 用量探针启动失败：\(message)"
        case .timedOut: return "Agent 用量读取超时"
        case .failed(let message): return message
        case .invalidResponse: return "Agent 用量探针返回了无法识别的数据"
        }
    }
}
