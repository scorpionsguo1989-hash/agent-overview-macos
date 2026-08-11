import Foundation

@main
struct CodexUsageProbeTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "planType": "test-plan",
                "primary": [
                    "usedPercent": 25.0,
                    "windowDurationMins": 300,
                    "resetsAt": 2_000_003_600,
                ],
                "secondary": [
                    "usedPercent": 40.0,
                    "windowDurationMins": 10_080,
                    "resetsAt": 2_000_086_400,
                ],
            ],
            "rateLimitResetCredits": ["availableCount": 1],
        ]

        let parsed = try CodexRateLimitParser.parse(
            result: result,
            sourcePath: "/tmp/codex-test-double",
            now: now
        )
        require(parsed.key == "cdx", "unexpected agent key")
        require(parsed.plan == "test-plan", "plan was not parsed")
        require(parsed.windows.map(\.label) == ["5-hour window", "1-week window"], "window labels differ")
        require(parsed.windows.map(\.remainingPercent) == [75, 60], "remaining percentages differ")
        require(parsed.note == "Full reset ×1", "reset credit note differs")
        require(parsed.sourceUpdatedAt == now, "source timestamp differs")
        print("Codex usage parser tests: PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("CodexUsageProbeTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
