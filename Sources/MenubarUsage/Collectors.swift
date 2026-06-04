import Foundation

// MARK: - Codex / ChatGPT collector
//
// Reads ChatGPT (Codex) usage. Codex is OpenAI's coding agent that runs against
// your ChatGPT plan, so its primary (5-hour) and secondary (weekly) rate-limit
// windows are exactly your ChatGPT subscription's limits.
//
// Primary source is the live endpoint `chatgpt.com/backend-api/wham/usage`
// (the same data the Codex TUI `/status` shows), authenticated with the token
// Codex already wrote to `~/.codex/auth.json`. Falls back to scanning
// `token_count` events in `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl`.
struct CodexUsageCollector: UsageCollecting {
    let provider: Provider = .codex

    private struct Window: Decodable {
        let used_percent: Double
        let resets_at: Double?
    }
    private struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }
    private struct TokenUsage: Decodable {
        let total_tokens: Int?
    }
    private struct Info: Decodable {
        let total_token_usage: TokenUsage?
    }
    private struct TokenCountPayload: Decodable {
        let type: String
        let info: Info?
        let rate_limits: RateLimits?
    }
    private struct Event: Decodable {
        let timestamp: String?
        let payload: TokenCountPayload?
    }

    private static func sessionFiles(limit: Int) -> [URL] {
        let sessionsDir = DataFiles.expand("~/.codex/sessions")
        return Array(DataFiles.recentDatePartitionedFiles(
            in: sessionsDir,
            extensions: ["jsonl"],
            limit: limit
        ).prefix(limit))
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // In-memory cache of the last successful live-API response. The endpoint sits
    // on the same backend the Codex CLI uses, so we refresh at most once per
    // `liveMinInterval` and serve the cached live data in between.
    private static let liveCacheLock = NSLock()
    private nonisolated(unsafe) static var liveCache: UsageSnapshot?
    private nonisolated(unsafe) static var liveCacheAt: Date?
    private static let liveMinInterval: TimeInterval = 30

    private static func freshLiveSnapshot() -> UsageSnapshot? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        guard let snapshot = liveCache, let at = liveCacheAt,
              Date().timeIntervalSince(at) < liveMinInterval else { return nil }
        return snapshot
    }

    private static func lastLiveSnapshot() -> UsageSnapshot? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        return liveCache
    }

    private static func storeLiveSnapshot(_ snapshot: UsageSnapshot) {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        liveCache = snapshot
        liveCacheAt = Date()
    }

    private struct Auth: Decodable {
        let tokens: Tokens
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String?
        }
    }

    /// Reads the ChatGPT access token + account id Codex already wrote to
    /// `~/.codex/auth.json`.
    private static func loadAuth() -> Auth? {
        let path = DataFiles.expand("~/.codex/auth.json")
        guard let data = FileManager.default.contents(atPath: path),
              let auth = try? JSONDecoder().decode(Auth.self, from: data),
              !auth.tokens.access_token.isEmpty else { return nil }
        return auth
    }

    func collect() async -> UsageSnapshot {
        guard AuthDetector.current().isConnected(.codex) else {
            return .disconnected(.codex)
        }

        if let cached = Self.freshLiveSnapshot() { return cached }
        if let live = await Self.fetchLiveSnapshotShared() {
            Self.storeLiveSnapshot(live)
            return live
        }
        if let stale = Self.lastLiveSnapshot() { return stale }

        return collectFromRollouts()
    }

    /// Single shared in-flight request, so a periodic tick and a manual refresh
    /// don't both hammer `wham/usage` at the same instant.
    private final class InflightBox: @unchecked Sendable {
        fileprivate final class Token {}
        private let lock = NSLock()
        private var currentToken: Token?
        private var currentTask: Task<UsageSnapshot?, Never>?

        fileprivate func startOrJoin(_ factory: @escaping @Sendable () async -> UsageSnapshot?) -> (Task<UsageSnapshot?, Never>, Token) {
            lock.lock()
            if let existing = currentTask, let existingToken = currentToken {
                lock.unlock()
                return (existing, existingToken)
            }
            let token = Token()
            let new = Task { await factory() }
            currentToken = token
            currentTask = new
            lock.unlock()
            return (new, token)
        }

        fileprivate func clear(_ token: Token) {
            lock.lock()
            if currentToken === token {
                currentToken = nil
                currentTask = nil
            }
            lock.unlock()
        }
    }
    private static let inflightBox = InflightBox()

    private static func fetchLiveSnapshotShared() async -> UsageSnapshot? {
        let (task, token) = inflightBox.startOrJoin { await fetchLiveSnapshot() }
        let result = await task.value
        inflightBox.clear(token)
        return result
    }

    private struct APIWindow: Decodable {
        let used_percent: Double?
        let reset_at: Double?
        let limit_window_seconds: Double?
    }
    private struct APIRateLimit: Decodable {
        let allowed: Bool?
        let limit_reached: Bool?
        let primary_window: APIWindow?
        let secondary_window: APIWindow?
    }
    private struct APIUsage: Decodable {
        let plan_type: String?
        let rate_limit: APIRateLimit?
    }

    private static func fetchLiveSnapshot() async -> UsageSnapshot? {
        guard let auth = loadAuth() else { return nil }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(auth.tokens.access_token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountID = auth.tokens.account_id, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("menubar-usage/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let usage = try? JSONDecoder().decode(APIUsage.self, from: data),
              let rate = usage.rate_limit else {
            return nil
        }

        guard rate.primary_window?.used_percent != nil || rate.secondary_window?.used_percent != nil else {
            return nil
        }

        return UsageSnapshot(
            provider: .codex,
            isConnected: true,
            dailyPercent: rate.primary_window?.used_percent,
            weeklyPercent: rate.secondary_window?.used_percent,
            dailyResetAt: rate.primary_window?.reset_at.map { Date(timeIntervalSince1970: $0) },
            weeklyResetAt: rate.secondary_window?.reset_at.map { Date(timeIntervalSince1970: $0) },
            totalTokens: nil,
            planLabel: usage.plan_type.map { $0.capitalized },
            updatedAt: Date(),
            error: nil
        )
    }

    /// JSONL-rollout fallback used when the live API is unreachable.
    private func collectFromRollouts() -> UsageSnapshot {
        let files = Self.sessionFiles(limit: 24)
        guard !files.isEmpty else {
            return .failure(.codex, message: "No Codex sessions found")
        }

        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var best: (date: Date, event: TokenCountPayload)?

        func consider(_ line: String) -> Bool {
            guard line.contains("\"token_count\"") else { return false }
            guard let data = line.data(using: .utf8),
                  let event = try? decoder.decode(Event.self, from: data),
                  let payload = event.payload, payload.type == "token_count",
                  payload.rate_limits != nil else { return false }
            let date = event.timestamp.flatMap { isoFormatter.date(from: $0) } ?? Date.distantPast
            if best == nil || date > best!.date {
                best = (date, payload)
            }
            return true
        }

        for file in files {
            for line in DataFiles.recentLines(in: file) {
                if consider(line) { break }
            }
        }

        if best == nil {
            for file in files.prefix(3) {
                DataFiles.forEachLine(in: file) { line in
                    _ = consider(line)
                }
            }
        }

        guard let result = best, let limits = result.event.rate_limits else {
            return .failure(.codex, message: "No usage telemetry yet")
        }

        return UsageSnapshot(
            provider: .codex,
            isConnected: true,
            dailyPercent: limits.primary?.used_percent,
            weeklyPercent: limits.secondary?.used_percent,
            dailyResetAt: limits.primary?.resets_at.map { Date(timeIntervalSince1970: $0) },
            weeklyResetAt: limits.secondary?.resets_at.map { Date(timeIntervalSince1970: $0) },
            totalTokens: result.event.info?.total_token_usage?.total_tokens,
            planLabel: limits.plan_type.map { $0.capitalized },
            updatedAt: result.date == .distantPast ? Date() : result.date,
            error: nil
        )
    }
}

// MARK: - Claude credentials

/// Reads Claude's OAuth credentials, preferring the on-disk
/// `~/.claude/.credentials.json` file (no Keychain prompt) and falling back to
/// the Keychain only when the file is absent. Cached in memory until near expiry.
enum ClaudeCredentials {
    struct OAuth: Decodable {
        let accessToken: String
        let subscriptionType: String?
        /// Unix epoch in milliseconds when the access token expires.
        let expiresAt: Double?

        var expiryDate: Date? {
            expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: OAuth?
    /// True while a (potentially prompting, slow) Keychain read is in flight, so
    /// we never queue up more than one and never spam the access prompt.
    private nonisolated(unsafe) static var keychainReading = false
    /// After a failed/denied Keychain read, wait until this time before trying
    /// again, so dismissing the prompt doesn't re-pop it every refresh tick.
    private nonisolated(unsafe) static var keychainRetryAfter: Date?
    private static let keychainCooldown: TimeInterval = 5 * 60

    /// Returns the current OAuth token **without ever blocking** on the Keychain.
    ///
    /// The Claude token lives in the macOS Keychain ("Claude Code-credentials").
    /// Reading it from a non-Claude binary triggers a synchronous authorization
    /// prompt the first time, which would otherwise freeze the whole refresh.
    /// So we: serve a still-valid cached token if we have one; else read the
    /// (prompt-free) on-disk credentials file; else kick the Keychain read off on
    /// a background queue and return whatever we have right now (often `nil` on
    /// the very first call). Once the user approves the prompt, the background
    /// read caches the token and the next refresh picks it up.
    static func currentNonBlocking() -> OAuth? {
        lock.lock()

        if let cached, let expiry = cached.expiryDate, expiry.timeIntervalSinceNow > 120 {
            lock.unlock()
            return cached
        }

        // Prompt-free file read first (most installs have this; this one doesn't).
        if let fromFile = readFromFile() {
            cached = fromFile
            lock.unlock()
            return fromFile
        }

        let current = cached
        let cooling = keychainRetryAfter.map { $0 > Date() } ?? false
        let shouldStartRead = !keychainReading && !cooling
        if shouldStartRead { keychainReading = true }
        lock.unlock()

        if shouldStartRead {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = readFromKeychain() // may show a one-time prompt
                lock.lock()
                if let result {
                    cached = result
                    keychainRetryAfter = nil
                } else {
                    // Denied / unavailable: back off before prompting again.
                    keychainRetryAfter = Date().addingTimeInterval(keychainCooldown)
                }
                keychainReading = false
                lock.unlock()
            }
        }

        return current
    }

    private struct Wrapper: Decodable { let claudeAiOauth: OAuth }

    private static func readFromFile() -> OAuth? {
        let paths = [
            "~/.claude/.credentials.json",
            "~/.config/claude/credentials.json"
        ]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: DataFiles.expand(path)) else { continue }
            if let oauth = try? JSONDecoder().decode(Wrapper.self, from: data).claudeAiOauth {
                return oauth
            }
        }
        return nil
    }

    private static func readFromKeychain() -> OAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Wrapper.self, from: data).claudeAiOauth
    }
}

// MARK: - Claude collector

/// Reads Claude Code's **live** usage limits from the same endpoint the CLI's
/// `/usage` command uses: `GET https://api.anthropic.com/api/oauth/usage`.
/// Falls back to a local token-throughput estimate parsed from
/// `~/.claude/projects/**/*.jsonl` when the API is unreachable.
struct ClaudeUsageCollector: UsageCollecting {
    let provider: Provider = .claude

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private struct Window: Decodable {
        let utilization: Double
        let resets_at: String?
    }
    private struct LiveUsage: Decodable {
        let five_hour: Window?
        let seven_day: Window?
    }

    // The endpoint is aggressively rate-limited (HTTP 429), so we hit the network
    // at most once per `liveMinInterval` and serve the cached live snapshot between.
    private static let liveCacheLock = NSLock()
    private nonisolated(unsafe) static var liveCache: UsageSnapshot?
    private nonisolated(unsafe) static var liveCacheAt: Date?
    private static let liveMinInterval: TimeInterval = 5 * 60

    private static func freshLiveSnapshot() -> UsageSnapshot? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        guard let snapshot = liveCache, let at = liveCacheAt,
              Date().timeIntervalSince(at) < liveMinInterval else { return nil }
        return snapshot
    }

    private static func lastLiveSnapshot() -> UsageSnapshot? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        return liveCache
    }

    private static func storeLiveSnapshot(_ snapshot: UsageSnapshot) {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        liveCache = snapshot
        liveCacheAt = Date()
    }

    func collect() async -> UsageSnapshot {
        guard AuthDetector.current().isConnected(.claude) else {
            return .disconnected(.claude)
        }

        if let cached = Self.freshLiveSnapshot() {
            return cached
        }

        if let live = await liveSnapshot() {
            Self.storeLiveSnapshot(live)
            return live
        }

        if let stale = Self.lastLiveSnapshot() {
            return stale
        }
        return estimatedSnapshot()
    }

    // MARK: Live API

    private func liveSnapshot() async -> UsageSnapshot? {
        guard let credentials = ClaudeCredentials.currentNonBlocking() else { return nil }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let usage = try? JSONDecoder().decode(LiveUsage.self, from: data) else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parseDate: (String?) -> Date? = { stamp in
            guard let stamp else { return nil }
            return isoFormatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        }

        let plan = credentials.subscriptionType
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }

        return UsageSnapshot(
            provider: .claude,
            isConnected: true,
            dailyPercent: usage.five_hour?.utilization,
            weeklyPercent: usage.seven_day?.utilization,
            dailyResetAt: parseDate(usage.five_hour?.resets_at),
            weeklyResetAt: parseDate(usage.seven_day?.resets_at),
            totalTokens: nil,
            planLabel: plan,
            updatedAt: Date(),
            error: nil
        )
    }

    // MARK: Local fallback estimate

    private var fiveHourTokenBudget: Int { AppConfig.shared.claudeFiveHourTokenBudget ?? 90_000_000 }
    private var weeklyTokenBudget: Int { AppConfig.shared.claudeWeeklyTokenBudget ?? 440_000_000 }

    private struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
    private struct Message: Decodable {
        let usage: Usage?
    }
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let message: Message?
    }

    private func estimatedSnapshot() -> UsageSnapshot {
        let projectsDir = DataFiles.expand("~/.claude/projects")
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)

        let files = DataFiles.recentFiles(in: projectsDir, extensions: ["jsonl"], modifiedAfter: weekAgo)
        guard !files.isEmpty else {
            return .failure(.claude, message: "Offline — no cached usage")
        }

        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var fiveHourTokens = 0
        var weeklyTokens = 0
        var oldestFiveHour: Date?
        var oldestWeekly: Date?
        var latest = Date.distantPast

        for file in files {
            DataFiles.forEachLine(in: file) { line in
                guard line.contains("\"usage\"") else { return }
                guard let data = line.data(using: .utf8),
                      let parsed = try? decoder.decode(Line.self, from: data),
                      parsed.type == "assistant",
                      let usage = parsed.message?.usage,
                      let stamp = parsed.timestamp,
                      let date = isoFormatter.date(from: stamp) else { return }

                let tokens = (usage.input_tokens ?? 0)
                    + (usage.output_tokens ?? 0)
                    + (usage.cache_creation_input_tokens ?? 0)
                    + (usage.cache_read_input_tokens ?? 0)
                guard tokens > 0 else { return }

                if date >= weekAgo {
                    weeklyTokens += tokens
                    latest = max(latest, date)
                    if oldestWeekly == nil || date < oldestWeekly! { oldestWeekly = date }
                }
                if date >= fiveHoursAgo {
                    fiveHourTokens += tokens
                    if oldestFiveHour == nil || date < oldestFiveHour! { oldestFiveHour = date }
                }
            }
        }

        guard weeklyTokens > 0 else {
            return .failure(.claude, message: "No usage in the last 7 days")
        }

        let dailyPercent = min(100, Double(fiveHourTokens) / Double(fiveHourTokenBudget) * 100)
        let weeklyPercent = min(100, Double(weeklyTokens) / Double(weeklyTokenBudget) * 100)

        return UsageSnapshot(
            provider: .claude,
            isConnected: true,
            dailyPercent: dailyPercent,
            weeklyPercent: weeklyPercent,
            dailyResetAt: oldestFiveHour?.addingTimeInterval(5 * 3600),
            weeklyResetAt: oldestWeekly?.addingTimeInterval(7 * 24 * 3600),
            totalTokens: weeklyTokens,
            planLabel: AppConfig.shared.claudePlanLabel ?? "est.",
            updatedAt: latest == .distantPast ? now : latest,
            error: nil
        )
    }
}
