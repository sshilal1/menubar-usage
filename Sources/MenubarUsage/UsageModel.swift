import AppKit
import Foundation
import Security

// MARK: - Data model
//
// The data-collection layer in this file is adapted from Neelash Kannan's
// `usage-touchbar` project (https://github.com/neelashkannan/usage-touchbar),
// trimmed to the two providers we care about — Claude and ChatGPT/Codex — and
// reused unchanged in behavior. The UI on top of it (menu bar + popover) is new.

/// A structured, real-data snapshot of a provider's usage.
///
/// `dailyPercent` / `weeklyPercent` are the share of the rolling primary
/// (5-hour) and secondary (weekly) limit windows that have been consumed.
struct UsageSnapshot: Sendable {
    let provider: Provider
    let isConnected: Bool
    let dailyPercent: Double?
    let weeklyPercent: Double?
    let dailyResetAt: Date?
    let weeklyResetAt: Date?
    let totalTokens: Int?
    let planLabel: String?
    let updatedAt: Date
    let error: String?

    /// The most-constrained window — used to color the menu bar gauge.
    var headlinePercent: Double? {
        switch (dailyPercent, weeklyPercent) {
        case let (d?, w?): return max(d, w)
        case let (d?, nil): return d
        case let (nil, w?): return w
        default: return nil
        }
    }

    static func disconnected(_ provider: Provider) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            isConnected: false,
            dailyPercent: nil,
            weeklyPercent: nil,
            dailyResetAt: nil,
            weeklyResetAt: nil,
            totalTokens: nil,
            planLabel: nil,
            updatedAt: Date(),
            error: "Login required"
        )
    }

    static func failure(_ provider: Provider, message: String) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            isConnected: true,
            dailyPercent: nil,
            weeklyPercent: nil,
            dailyResetAt: nil,
            weeklyResetAt: nil,
            totalTokens: nil,
            planLabel: nil,
            updatedAt: Date(),
            error: message
        )
    }
}

enum Provider: String, CaseIterable, Sendable {
    case claude = "Claude"
    case codex = "ChatGPT"

    var symbol: String { rawValue }

    /// Single-letter badge used in the compact menu bar gauge.
    var menuBarBadge: String {
        switch self {
        case .claude: "C"
        case .codex: "G"
        }
    }

    /// Text badge used only when a provider has no app icon or custom mark.
    var fallbackBadge: String {
        switch self {
        case .claude: "C"
        case .codex: "G"
        }
    }

    var loginURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/login")!
        case .codex: URL(string: "https://chatgpt.com/codex")!
        }
    }

    var accentColor: NSColor {
        switch self {
        case .claude: NSColor(calibratedRed: 0.85, green: 0.49, blue: 0.30, alpha: 1)
        case .codex: NSColor(calibratedRed: 0.10, green: 0.65, blue: 0.53, alpha: 1)
        }
    }
}

enum UsageFormat {
    /// Color graded by how much of a limit is consumed.
    static func color(forPercent percent: Double) -> NSColor {
        switch percent {
        case ..<60: NSColor.systemGreen
        case ..<85: NSColor.systemOrange
        default: NSColor.systemRed
        }
    }

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func tokenText(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "now" }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct AuthState {
    let connectedProviders: Set<Provider>

    func isConnected(_ provider: Provider) -> Bool {
        connectedProviders.contains(provider)
    }
}

enum AuthDetector {
    static func current() -> AuthState {
        AuthState(connectedProviders: Set(Provider.allCases.filter { provider in
            authPaths(for: provider).contains { FileManager.default.fileExists(atPath: expand($0)) }
        }))
    }

    static func authPaths(for provider: Provider) -> [String] {
        switch provider {
        case .codex:
            [
                "~/.codex/auth.json",
                "~/.codex/config.toml"
            ]
        case .claude:
            [
                "~/.claude.json",
                "~/.claude/.credentials.json",
                "~/.claude/config.json",
                "~/.config/claude/credentials.json"
            ]
        }
    }

    private static func expand(_ path: String) -> String {
        path.replacingOccurrences(
            of: "~",
            with: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

protocol UsageCollecting: Sendable {
    var provider: Provider { get }
    func collect() async -> UsageSnapshot
}

final class UsageStore: @unchecked Sendable {
    private let collectors: [UsageCollecting]
    private let queue = DispatchQueue(label: "MenubarUsage.UsageStore")
    private var snapshots: [Provider: UsageSnapshot] = [:]

    init(collectors: [UsageCollecting]) {
        self.collectors = collectors
    }

    func currentSnapshots() -> [UsageSnapshot] {
        queue.sync {
            Provider.allCases.compactMap { snapshots[$0] }
        }
    }

    func refresh() async -> [UsageSnapshot] {
        DebugLog.write("refresh begin")
        let collected = await withTaskGroup(of: UsageSnapshot.self) { group in
            for collector in collectors {
                group.addTask { await Self.collectWithDeadline(collector, seconds: 12) }
            }

            var results: [UsageSnapshot] = []
            for await snapshot in group {
                results.append(snapshot)
            }
            return results.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
        DebugLog.write("refresh end (\(collected.count) snapshots)")

        queue.sync {
            for snapshot in collected {
                snapshots[snapshot.provider] = snapshot
            }
        }

        return currentSnapshots()
    }

    /// Runs `collector.collect()` but never lets a single provider stall the whole
    /// refresh. The work runs on a detached task so that if it gets stuck (e.g. on
    /// a blocking system call), this function still returns at the deadline and the
    /// gauge updates with whatever else is ready. The stuck work is abandoned; its
    /// side effects (cache population) are still useful on the next tick.
    private static func collectWithDeadline(_ collector: UsageCollecting, seconds: Double) async -> UsageSnapshot {
        let p = collector.provider.rawValue
        DebugLog.write("deadline start \(p)")
        let gate = ResumeGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<UsageSnapshot, Never>) in
            Task.detached {
                let snapshot = await collector.collect()
                DebugLog.write("collect done \(p)")
                if gate.tryClaim() { cont.resume(returning: snapshot) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                DebugLog.write("deadline fired \(p)")
                if gate.tryClaim() {
                    cont.resume(returning: .failure(collector.provider, message: "Updating…"))
                }
            }
        }
    }
}

/// Unbuffered stderr tracing, gated on the MENUBAR_USAGE_DEBUG env var.
enum DebugLog {
    nonisolated(unsafe) static let enabled = ProcessInfo.processInfo.environment["MENUBAR_USAGE_DEBUG"] != nil
    static func write(_ message: String) {
        guard enabled else { return }
        let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

/// One-shot gate so exactly one of two racing tasks resumes the continuation.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func tryClaim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Shared helpers for locating and reading provider data files.
enum DataFiles {
    static func home() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func expand(_ path: String) -> String {
        path.replacingOccurrences(of: "~", with: home())
    }

    /// Returns regular files under `directory` (recursively) sorted newest first.
    static func recentFiles(
        in directory: String,
        extensions: Set<String>,
        modifiedAfter: Date? = nil,
        maxInspected: Int = 5_000
    ) -> [URL] {
        let root = URL(fileURLWithPath: directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var matches: [(URL, Date)] = []
        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > maxInspected { break }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if let cutoff = modifiedAfter, modified < cutoff { continue }
            matches.append((url, modified))
        }

        return matches.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Returns the newest files under a date-partitioned tree of the form
    /// `<directory>/<Y>/<M>/<D>/...`, sorted newest first. Descends into the most
    /// recent date folders and stops once it has gathered at least `limit` files,
    /// so the currently-active session is always seen no matter how many
    /// historical sessions have accumulated.
    static func recentDatePartitionedFiles(
        in directory: String,
        extensions: Set<String>,
        limit: Int
    ) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        func subdirectoriesDescending(_ url: URL) -> [URL] {
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { a, b in
                    if let na = Int(a.lastPathComponent), let nb = Int(b.lastPathComponent) {
                        return na > nb
                    }
                    return a.lastPathComponent > b.lastPathComponent
                }
        }

        func files(in url: URL) -> [(URL, Date)] {
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.compactMap { file in
                guard extensions.contains(file.pathExtension.lowercased()) else { return nil }
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { return nil }
                return (file, values?.contentModificationDate ?? .distantPast)
            }
        }

        var matches: [(URL, Date)] = []
        let root = URL(fileURLWithPath: directory)
        for year in subdirectoriesDescending(root) {
            for month in subdirectoriesDescending(year) {
                for day in subdirectoriesDescending(month) {
                    matches.append(contentsOf: files(in: day))
                    if matches.count >= limit { break }
                }
                if matches.count >= limit { break }
            }
            if matches.count >= limit { break }
        }

        if matches.isEmpty {
            matches.append(contentsOf: files(in: root))
        }

        return matches.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Streams a file line by line without loading the whole file into memory.
    static func forEachLine(in url: URL, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = UInt8(ascii: "\n")
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { return false }
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    body(line)
                }
            }
            return true
        }) {}

        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
            body(line)
        }
    }

    /// Returns complete lines near the end of a file, newest first.
    static func recentLines(in url: URL, maxBytes: UInt64 = 1024 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return [] }

        let bytesToRead = min(size, maxBytes)
        try? handle.seek(toOffset: size - bytesToRead)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let completeLines = bytesToRead < size ? lines.dropFirst() : lines[...]
        return completeLines.reversed().map(String.init)
    }
}

/// Optional user configuration, read from `~/.config/menubar-usage/config.json`.
/// Anthropic does not publish exact token limits for Claude Code, so the Claude
/// percentage is an estimate against these budgets when the live API is
/// unavailable.
///
///     {
///       "claudeFiveHourTokenBudget": 90000000,
///       "claudeWeeklyTokenBudget": 440000000,
///       "claudePlanLabel": "Max 20x"
///     }
struct AppConfig: Codable {
    var claudeFiveHourTokenBudget: Int?
    var claudeWeeklyTokenBudget: Int?
    var claudePlanLabel: String?

    nonisolated(unsafe) static var shared = load()

    static func reload() { shared = load() }

    private static var configPath: String { DataFiles.expand("~/.config/menubar-usage/config.json") }

    private static func load() -> AppConfig {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }
}
