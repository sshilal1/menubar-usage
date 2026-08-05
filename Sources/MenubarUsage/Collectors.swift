import Foundation
import Security
import SQLite3

// MARK: - Codex / ChatGPT collector
//
// Reads ChatGPT (Codex) usage. Codex is OpenAI's coding agent that runs against
// your ChatGPT plan, so its primary and secondary rate-limit windows are
// exactly your ChatGPT subscription's limits. The API may expose one window
// (currently a weekly window for some plans) or two windows.
//
// Primary source is the live endpoint `chatgpt.com/backend-api/wham/usage`
// (the same data the Codex TUI `/status` shows), authenticated with the token
// Codex already wrote to `~/.codex/auth.json`. Falls back to scanning
// `token_count` events in `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl`.
struct CodexUsageCollector: UsageCollecting {
    let provider: Provider = .codex

    private struct Window: Decodable {
        let used_percent: Double?
        let window_minutes: Double?
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

        let primary = usageWindow(from: rate.primary_window)
        let secondary = usageWindow(from: rate.secondary_window)
        guard primary != nil || secondary != nil else {
            return nil
        }

        return UsageSnapshot(
            provider: .codex,
            isConnected: true,
            primaryWindow: primary,
            secondaryWindow: secondary,
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
            primaryWindow: Self.usageWindow(from: limits.primary, fallbackLabel: "Primary"),
            secondaryWindow: Self.usageWindow(from: limits.secondary, fallbackLabel: "Secondary"),
            totalTokens: result.event.info?.total_token_usage?.total_tokens,
            planLabel: limits.plan_type.map { $0.capitalized },
            updatedAt: result.date == .distantPast ? Date() : result.date,
            error: nil
        )
    }

    private static func usageWindow(from window: APIWindow?) -> UsageWindow? {
        guard let window,
              window.used_percent != nil || window.reset_at != nil else { return nil }
        return UsageWindow(
            label: label(forSeconds: window.limit_window_seconds),
            percent: window.used_percent,
            resetAt: window.reset_at.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func usageWindow(from window: Window?, fallbackLabel: String) -> UsageWindow? {
        guard let window,
              window.used_percent != nil || window.resets_at != nil else { return nil }
        return UsageWindow(
            label: label(forMinutes: window.window_minutes, fallback: fallbackLabel),
            percent: window.used_percent,
            resetAt: window.resets_at.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func label(forSeconds seconds: Double?) -> String {
        guard let seconds else { return "Primary" }
        return label(forMinutes: seconds / 60, fallback: "Primary")
    }

    private static func label(forMinutes minutes: Double?, fallback: String) -> String {
        guard let minutes else { return fallback }
        if abs(minutes - 300) < 1 { return "5-hour" }
        if minutes >= 7 * 24 * 60 - 1 { return "Weekly" }
        if minutes >= 24 * 60 - 1 {
            return "\(Int((minutes / (24 * 60)).rounded()))-day"
        }
        return "\(Int((minutes / 60).rounded()))-hour"
    }
}

// MARK: - Claude credentials

/// Reads Claude's OAuth credentials, preferring the on-disk
/// `~/.claude/.credentials.json` file (no Keychain prompt) and falling back to
/// the Keychain only when the file is absent. Cached in memory until near expiry.
enum ClaudeCredentials {
    struct OAuth: Codable {
        let accessToken: String
        let refreshToken: String?
        let subscriptionType: String?
        /// Unix epoch in milliseconds when the access token expires.
        let expiresAt: Double?
        let scopes: [String]?
        let rateLimitTier: String?

        var expiryDate: Date? {
            expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        var isExpired: Bool {
            guard let expiry = expiryDate else { return false }
            return expiry.timeIntervalSinceNow < 120
        }
    }

    // OAuth refresh endpoint + public client id, taken from the Claude Code binary
    // (`platform.claude.com/v1/oauth/token`). The access token is short-lived (~8h);
    // this app refreshes it with the stored refresh token, just like the CLI.
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

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
            DebugLog.write("claude-cred: starting background keychain read for 'Claude Code-credentials'")
            DispatchQueue.global(qos: .userInitiated).async {
                let (result, status) = readFromKeychain() // one-time bootstrap prompt
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

                if let result {
                    // Seed our own file so subsequent runs never read the Keychain again.
                    writeToFile(result)
                    DebugLog.write("claude-cred: keychain read OK — token acquired"
                        + " (expires \(result.expiryDate.map { timestamp($0) } ?? "?")); cached to file")
                } else {
                    DebugLog.write("claude-cred: keychain read FAILED — \(keychainErrorText(status));"
                        + " backing off \(Int(keychainCooldown))s before retry."
                        + " The Claude gauge will show the local estimate until this succeeds.")
                }
            }
        } else if current == nil {
            DebugLog.write("claude-cred: no token yet"
                + (cooling ? " (in keychain back-off window)" : " (keychain read already in flight)"))
        }

        return current
    }

    /// Synchronous keychain read for the `--once` CLI diagnostic only. Blocks (and
    /// may show the authorization prompt) so the one-shot path can actually exercise
    /// the live API on machines where the token lives *only* in the Keychain — there
    /// `currentNonBlocking()` always returns nil on first call, so without this the
    /// `--once` readout could never show live Claude data and was misleading.
    ///
    /// Never call this from the GUI: a synchronous keychain prompt would freeze the
    /// refresh (see `currentNonBlocking()`'s doc comment).
    static func prewarmBlocking() {
        lock.lock()
        if let cached, let expiry = cached.expiryDate, expiry.timeIntervalSinceNow > 120 {
            lock.unlock()
            return
        }
        if let fromFile = readFromFile() {
            cached = fromFile
            lock.unlock()
            DebugLog.write("claude-cred: [--once] token loaded from credentials file")
            return
        }
        lock.unlock()

        DebugLog.write("claude-cred: [--once] blocking keychain read (may prompt)…")
        let (result, status) = readFromKeychain()
        lock.lock()
        if let result { cached = result }
        lock.unlock()
        if let result {
            writeToFile(result)
            DebugLog.write("claude-cred: [--once] keychain read OK — token acquired; cached to file")
        } else {
            DebugLog.write("claude-cred: [--once] keychain read FAILED — \(keychainErrorText(status))")
        }
    }

    /// Human-readable `(message + numeric code)` for a Keychain `OSStatus`, e.g.
    /// `-25308` → "Interaction is not allowed with the Security Server." Common ones:
    /// `-25300` item not found, `-25293` auth failed, `-25308` interaction not allowed
    /// (the LaunchAgent can't show a prompt), `-128` user cancelled the prompt.
    private static func keychainErrorText(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "\(message) (OSStatus \(status))"
    }

    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }

    private struct Wrapper: Codable { let claudeAiOauth: OAuth }

    /// The app's OWN copy of the credential, kept current on every refresh. We read
    /// this **first** (a plain file read never prompts) and only touch the Keychain
    /// to bootstrap it. Refreshed tokens are written *here*, never back to Claude
    /// Code's Keychain item — modifying that item re-prompts every session, which is
    /// the whole problem this avoids. (ChatGPT/Codex never prompts for the same
    /// reason: its token is a plain file at `~/.codex/auth.json`.)
    private static var appCredentialsPath: String {
        DataFiles.expand("~/.config/menubar-usage/credentials.json")
    }

    private static func readFromFile() -> OAuth? {
        let paths = [
            appCredentialsPath,
            DataFiles.expand("~/.claude/.credentials.json"),
            DataFiles.expand("~/.config/claude/credentials.json")
        ]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            if let oauth = try? JSONDecoder().decode(Wrapper.self, from: data).claudeAiOauth {
                return oauth
            }
        }
        return nil
    }

    /// Persists the credential to the app's own file (mode 0600). Never touches the
    /// Keychain, so it never prompts.
    @discardableResult
    private static func writeToFile(_ oauth: OAuth) -> Bool {
        let dir = DataFiles.expand("~/.config/menubar-usage")
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(Wrapper(claudeAiOauth: oauth)) else { return false }
        try? FileManager.default.removeItem(atPath: appCredentialsPath)
        return FileManager.default.createFile(
            atPath: appCredentialsPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }

    /// Reads the token from the Keychain, returning both the decoded OAuth (if any)
    /// and the raw `OSStatus` so callers can log *why* a read failed.
    private static func readFromKeychain() -> (oauth: OAuth?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, status)
        }
        return (try? JSONDecoder().decode(Wrapper.self, from: data).claudeAiOauth, status)
    }

    // MARK: Refresh

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    /// Synchronous cache update (NSLock can't be held across an async boundary).
    private static func storeCached(_ oauth: OAuth) {
        lock.lock()
        cached = oauth
        keychainRetryAfter = nil
        lock.unlock()
    }

    /// Exchanges the stored refresh token for a fresh access token (the same flow
    /// Claude Code uses) and saves it to the app's own credentials file. Returns the
    /// new token, or nil on failure.
    ///
    /// We deliberately do **not** write the new token back into Claude Code's
    /// Keychain item: modifying another app's Keychain item re-prompts the user every
    /// session (that's the bug this avoids). The trade-off is that the CLI's Keychain
    /// copy can drift, so the `claude` CLI may ask you to log in again once. A
    /// rejected refresh request does not consume the refresh token.
    static func refreshIfPossible(_ current: OAuth) async -> OAuth? {
        guard let refreshToken = current.refreshToken else {
            DebugLog.write("claude-cred: cannot refresh — no refresh token available")
            return nil
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            DebugLog.write("claude-cred: token refresh request errored — \(error.localizedDescription)")
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            DebugLog.write("claude-cred: token refresh FAILED — HTTP \(http.statusCode)."
                + " The refresh token may be revoked; re-login Claude Code (`claude`).")
            return nil
        }

        let expiresAtMs = Date().addingTimeInterval(token.expires_in ?? 28_800)
            .timeIntervalSince1970 * 1000
        let refreshed = OAuth(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? refreshToken,
            subscriptionType: current.subscriptionType,
            expiresAt: expiresAtMs,
            scopes: current.scopes,
            rateLimitTier: current.rateLimitTier
        )

        let persisted = writeToFile(refreshed)
        storeCached(refreshed)

        DebugLog.write("claude-cred: token REFRESHED ok (new expiry"
            + " \(timestamp(refreshed.expiryDate ?? Date()))); file write"
            + " \(persisted ? "ok" : "FAILED — will retry refresh next tick")")
        return refreshed
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

    // Back-off after a *failed* live fetch. Without this, the `liveMinInterval`
    // throttle (which only applies after a success) doesn't kick in, so a 429 made
    // the app re-hit the rate-limited endpoint on every 20s tick — perpetuating the
    // throttle. After a failure we wait at least `liveFailureBackoff` (or the
    // server's `Retry-After`, capped) before trying again. Shares `liveCacheLock`.
    private nonisolated(unsafe) static var liveRetryAfter: Date?
    private static let liveFailureBackoff: TimeInterval = 90
    private static let maxFailureBackoff: TimeInterval = 10 * 60

    private static func inFailureBackoff() -> Date? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        if let until = liveRetryAfter, until > Date() { return until }
        return nil
    }

    private static func setFailureBackoff(seconds: TimeInterval) {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        liveRetryAfter = Date().addingTimeInterval(min(max(seconds, liveFailureBackoff), maxFailureBackoff))
    }

    private static func clearFailureBackoff() {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        liveRetryAfter = nil
    }

    func collect() async -> UsageSnapshot {
        guard AuthDetector.current().isConnected(.claude) else {
            DebugLog.write("claude: not signed in (no auth files found)")
            return .disconnected(.claude)
        }

        if let cached = Self.freshLiveSnapshot() {
            DebugLog.write("claude: serving fresh live cache (< \(Int(Self.liveMinInterval))s old)")
            return cached
        }

        if let until = Self.inFailureBackoff() {
            DebugLog.write("claude: in live-fetch back-off after a recent failure"
                + " (retrying in ~\(max(0, Int(until.timeIntervalSinceNow)))s) — not calling the API this tick")
            if let stale = Self.lastLiveSnapshot() { return stale }
            return estimatedSnapshot()
        }

        if let live = await liveSnapshot() {
            Self.storeLiveSnapshot(live)
            Self.clearFailureBackoff()
            DebugLog.write("claude: LIVE ok — 5h=\(pct(live.primaryWindow?.percent))"
                + " week=\(pct(live.secondaryWindow?.percent)) plan=\(live.planLabel ?? "—")")
            return live
        }

        if let stale = Self.lastLiveSnapshot() {
            DebugLog.write("claude: live fetch failed — serving STALE live cache"
                + " (last live update \(stale.updatedAt))")
            return stale
        }

        DebugLog.write("claude: live fetch failed and no cached live data —"
            + " FALLING BACK to local token ESTIMATE (numbers are approximate)")
        return estimatedSnapshot()
    }

    private func pct(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: Live API

    private func liveSnapshot() async -> UsageSnapshot? {
        guard var credentials = ClaudeCredentials.currentNonBlocking() else {
            DebugLog.write("claude: no OAuth token available — skipping live API call"
                + " (keychain not yet readable; see claude-cred logs above)")
            return nil
        }

        // Proactively refresh an expired/expiring access token before the API call.
        if credentials.isExpired {
            DebugLog.write("claude: access token expired/expiring (expires"
                + " \(Self.timestamp(credentials.expiryDate ?? Date()))) — refreshing before live call")
            guard let refreshed = await ClaudeCredentials.refreshIfPossible(credentials) else {
                Self.setFailureBackoff(seconds: Self.liveFailureBackoff)
                return nil
            }
            credentials = refreshed
        }

        var result = await fetchUsage(credentials: credentials)

        // A 401 despite the expiry check (clock skew / server-side revocation):
        // force a single refresh + retry.
        if result.status == 401 {
            DebugLog.write("claude: live API 401 — forcing a token refresh and one retry")
            if let refreshed = await ClaudeCredentials.refreshIfPossible(credentials) {
                credentials = refreshed
                result = await fetchUsage(credentials: credentials)
            }
        }

        guard result.status == 200 else {
            DebugLog.write("claude: live API returned HTTP \(result.status)"
                + " (401 = token rejected/expired, 429 = rate-limited)"
                + (result.retryAfter.map { "; Retry-After \(Int($0))s" } ?? ""))
            Self.setFailureBackoff(seconds: result.retryAfter ?? Self.liveFailureBackoff)
            return nil
        }
        guard let snapshot = result.snapshot else {
            DebugLog.write("claude: live API 200 but response was unusable (decode failed)")
            Self.setFailureBackoff(seconds: Self.liveFailureBackoff)
            return nil
        }
        return snapshot
    }

    private struct FetchResult {
        let snapshot: UsageSnapshot?
        let status: Int            // HTTP status; negative for transport errors
        let retryAfter: TimeInterval?
    }

    /// One `GET oauth/usage` call with the given token. No retry/backoff logic here —
    /// the caller decides based on `status` (so it can refresh + retry on 401).
    private func fetchUsage(credentials: ClaudeCredentials.OAuth) async -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            DebugLog.write("claude: live request errored — \(error.localizedDescription)")
            return FetchResult(snapshot: nil, status: -1, retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            DebugLog.write("claude: live response was not HTTP")
            return FetchResult(snapshot: nil, status: -2, retryAfter: nil)
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        guard http.statusCode == 200 else {
            return FetchResult(snapshot: nil, status: http.statusCode, retryAfter: retryAfter)
        }
        guard let usage = try? JSONDecoder().decode(LiveUsage.self, from: data) else {
            return FetchResult(snapshot: nil, status: 200, retryAfter: nil)
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parseDate: (String?) -> Date? = { stamp in
            guard let stamp else { return nil }
            return isoFormatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        }

        let plan = credentials.subscriptionType
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }

        let snapshot = UsageSnapshot(
            provider: .claude,
            isConnected: true,
            primaryWindow: UsageWindow(
                label: "5-hour",
                percent: usage.five_hour?.utilization,
                resetAt: parseDate(usage.five_hour?.resets_at)
            ),
            secondaryWindow: UsageWindow(
                label: "Weekly",
                percent: usage.seven_day?.utilization,
                resetAt: parseDate(usage.seven_day?.resets_at)
            ),
            totalTokens: nil,
            planLabel: plan,
            updatedAt: Date(),
            error: nil
        )
        return FetchResult(snapshot: snapshot, status: 200, retryAfter: nil)
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

        DebugLog.write("claude: ESTIMATE — 5h \(fiveHourTokens)/\(fiveHourTokenBudget) tok"
            + " = \(String(format: "%.0f%%", dailyPercent)),"
            + " week \(weeklyTokens)/\(weeklyTokenBudget) tok"
            + " = \(String(format: "%.0f%%", weeklyPercent))."
            + " These are guesses vs assumed budgets, NOT real limits.")

        return UsageSnapshot(
            provider: .claude,
            isConnected: true,
            primaryWindow: UsageWindow(
                label: "5-hour",
                percent: dailyPercent,
                resetAt: oldestFiveHour?.addingTimeInterval(5 * 3600)
            ),
            secondaryWindow: UsageWindow(
                label: "Weekly",
                percent: weeklyPercent,
                resetAt: oldestWeekly?.addingTimeInterval(7 * 24 * 3600)
            ),
            totalTokens: weeklyTokens,
            planLabel: AppConfig.shared.claudePlanLabel ?? "est.",
            updatedAt: latest == .distantPast ? now : latest,
            error: nil
        )
    }
}

// MARK: - Cursor credentials + collector
//
// Same pattern as Claude/Codex: read a local login token, then hit Cursor's
// usage endpoint. Token lives in Cursor's VS Code-state SQLite DB
// (`cursorAuth/accessToken`). Live numbers come from Connect RPC
// `DashboardService/GetCurrentPeriodUsage` — the same data Settings → Plan &
// Usage shows (Cursor Models / Other Models percentages + billing-cycle end).

enum CursorCredentials {
    private static let dbPath = DataFiles.expand(
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    )
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    private static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!

    /// App-owned copy of a refreshed access token. We never write back into
    /// Cursor's `state.vscdb` (same prompt-fatigue reason as Claude's Keychain).
    private static var appTokenPath: String {
        DataFiles.expand("~/.config/menubar-usage/cursor-token.json")
    }

    private struct StoredToken: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
    }

    static func accessToken() -> String? {
        if let stored = readAppToken(), !isExpired(stored) {
            return stored.accessToken
        }
        return readDBValue(key: "cursorAuth/accessToken")
    }

    static func refreshToken() -> String? {
        readAppToken()?.refreshToken
            ?? readDBValue(key: "cursorAuth/refreshToken")
    }

    static func membershipType() -> String? {
        readDBValue(key: "cursorAuth/stripeMembershipType")
    }

    /// Refresh the access token and stash it in our own file.
    static func refreshIfPossible() async -> String? {
        guard let refresh = refreshToken(), !refresh.isEmpty else {
            DebugLog.write("cursor-cred: no refresh token available")
            return nil
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            DebugLog.write("cursor-cred: token refresh request failed")
            return nil
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              !access.isEmpty else {
            DebugLog.write("cursor-cred: token refresh FAILED — HTTP \(http.statusCode)")
            return nil
        }
        if json["shouldLogout"] as? Bool == true {
            DebugLog.write("cursor-cred: refresh returned shouldLogout — re-login in Cursor")
            return nil
        }

        let expiresAt = jwtExpiry(access)
        let stored = StoredToken(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refresh,
            expiresAt: expiresAt
        )
        writeAppToken(stored)
        DebugLog.write("cursor-cred: token REFRESHED ok"
            + (expiresAt.map { " (expires \(ISO8601DateFormatter().string(from: $0)))" } ?? "")
            + "; file write ok")
        return access
    }

    private static func isExpired(_ stored: StoredToken) -> Bool {
        guard let expiresAt = stored.expiresAt else {
            return jwtExpiry(stored.accessToken).map { $0.timeIntervalSinceNow < 60 } ?? false
        }
        return expiresAt.timeIntervalSinceNow < 60
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload += String(repeating: "=", count: pad) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func readAppToken() -> StoredToken? {
        guard let data = FileManager.default.contents(atPath: appTokenPath),
              let stored = try? JSONDecoder().decode(StoredToken.self, from: data),
              !stored.accessToken.isEmpty else { return nil }
        return stored
    }

    private static func writeAppToken(_ stored: StoredToken) {
        let dir = DataFiles.expand("~/.config/menubar-usage")
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let ok = FileManager.default.createFile(
            atPath: appTokenPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        if !ok {
            try? data.write(to: URL(fileURLWithPath: appTokenPath), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: appTokenPath
            )
        }
    }

    /// Read a single `ItemTable` value from Cursor's state DB (read-only).
    private static func readDBValue(key: String) -> String? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK, let db else {
            DebugLog.write("cursor-cred: failed to open state.vscdb")
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let bindOK = key.withCString { cKey in
            sqlite3_bind_text(stmt, 1, cKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bindOK == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }
}

struct CursorUsageCollector: UsageCollecting {
    let provider: Provider = .cursor

    private static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!

    private static let liveCacheLock = NSLock()
    private nonisolated(unsafe) static var liveCache: UsageSnapshot?
    private nonisolated(unsafe) static var liveCacheAt: Date?
    private nonisolated(unsafe) static var liveRetryAfter: Date?
    private static let liveMinInterval: TimeInterval = 60
    private static let liveFailureBackoff: TimeInterval = 90
    private static let maxFailureBackoff: TimeInterval = 10 * 60

    private struct PlanUsage: Decodable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
        let includedSpend: Double?
        let limit: Double?
    }
    private struct PeriodUsage: Decodable {
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let planUsage: PlanUsage?
        let enabled: Bool?
    }

    func collect() async -> UsageSnapshot {
        guard AuthDetector.current().isConnected(.cursor) else {
            DebugLog.write("cursor: not signed in (no state.vscdb)")
            return .disconnected(.cursor)
        }

        if let cached = Self.freshLiveSnapshot() {
            DebugLog.write("cursor: serving fresh live cache (< \(Int(Self.liveMinInterval))s old)")
            return cached
        }

        if let until = Self.inFailureBackoff() {
            DebugLog.write("cursor: in live-fetch back-off"
                + " (retrying in ~\(max(0, Int(until.timeIntervalSinceNow)))s)")
            if let stale = Self.lastLiveSnapshot() { return stale }
            return .failure(.cursor, message: "Updating…")
        }

        if let live = await liveSnapshot() {
            Self.storeLiveSnapshot(live)
            Self.clearFailureBackoff()
            DebugLog.write("cursor: LIVE ok — models=\(pct(live.primaryWindow?.percent))"
                + " other=\(pct(live.secondaryWindow?.percent)) plan=\(live.planLabel ?? "—")")
            return live
        }

        if let stale = Self.lastLiveSnapshot() {
            DebugLog.write("cursor: live fetch failed — serving STALE live cache")
            return stale
        }

        DebugLog.write("cursor: live fetch failed and no cache")
        return .failure(.cursor, message: "Couldn't reach Cursor usage API")
    }

    private func pct(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    private func liveSnapshot() async -> UsageSnapshot? {
        guard var token = CursorCredentials.accessToken() else {
            DebugLog.write("cursor: no access token in state.vscdb")
            return nil
        }

        var result = await fetchUsage(token: token)
        if result.status == 401 {
            DebugLog.write("cursor: live API 401 — refreshing token and retrying")
            if let refreshed = await CursorCredentials.refreshIfPossible() {
                token = refreshed
                result = await fetchUsage(token: token)
            }
        }

        guard result.status == 200 else {
            DebugLog.write("cursor: live API returned HTTP \(result.status)")
            Self.setFailureBackoff(seconds: Self.liveFailureBackoff)
            return nil
        }
        guard let snapshot = result.snapshot else {
            DebugLog.write("cursor: live API 200 but decode failed")
            Self.setFailureBackoff(seconds: Self.liveFailureBackoff)
            return nil
        }
        return snapshot
    }

    private struct FetchResult {
        let snapshot: UsageSnapshot?
        let status: Int
    }

    private func fetchUsage(token: String) async -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            DebugLog.write("cursor: live request errored — \(error.localizedDescription)")
            return FetchResult(snapshot: nil, status: -1)
        }
        guard let http = response as? HTTPURLResponse else {
            return FetchResult(snapshot: nil, status: -2)
        }
        guard http.statusCode == 200 else {
            return FetchResult(snapshot: nil, status: http.statusCode)
        }
        guard let usage = try? JSONDecoder().decode(PeriodUsage.self, from: data),
              let plan = usage.planUsage else {
            return FetchResult(snapshot: nil, status: 200)
        }

        let resetAt = Self.parseMillis(usage.billingCycleEnd)
        let planLabel = CursorCredentials.membershipType().map { $0.capitalized } ?? "Pro"

        // Settings → Plan & Usage: "Cursor Models" (auto) and "Other Models" (api).
        let snapshot = UsageSnapshot(
            provider: .cursor,
            isConnected: true,
            primaryWindow: UsageWindow(
                label: "Models",
                percent: plan.autoPercentUsed,
                resetAt: resetAt
            ),
            secondaryWindow: UsageWindow(
                label: "Other",
                percent: plan.apiPercentUsed,
                resetAt: resetAt
            ),
            totalTokens: nil,
            planLabel: planLabel,
            updatedAt: Date(),
            error: nil
        )
        return FetchResult(snapshot: snapshot, status: 200)
    }

    private static func parseMillis(_ value: String?) -> Date? {
        guard let value, let ms = Double(value) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

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

    private static func inFailureBackoff() -> Date? {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        guard let until = liveRetryAfter, until > Date() else { return nil }
        return until
    }

    private static func setFailureBackoff(seconds: TimeInterval) {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        liveRetryAfter = Date().addingTimeInterval(min(max(seconds, liveFailureBackoff), maxFailureBackoff))
    }

    private static func clearFailureBackoff() {
        liveCacheLock.lock()
        defer { liveCacheLock.unlock() }
        liveRetryAfter = nil
    }
}
