import Foundation

// Only fixed categories and counters belong here; never pass peer messages or credentials.
enum DiagnosticLog {
    static let enabledKey = "detailedDiagnosticsEnabled"
    static let eventsKey = "detailedDiagnosticEvents"
    #if DEBUG
    static let defaultEnabled = true
    #else
    static let defaultEnabled = false
    #endif
    private static let lock = NSLock()
    private static var run = "none"
    private static var started = ProcessInfo.processInfo.systemUptime
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? defaultEnabled
    }

    static func begin(_ operation: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        run = UUID().uuidString
        started = ProcessInfo.processInfo.systemUptime
        append("begin operation=\(operation)")
        append("os=\(ProcessInfo.processInfo.operatingSystemVersionString) app=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
    }

    static func event(_ detail: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        append(detail)
    }

    private static func append(_ detail: String) {
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        let line = "\(Date().timeIntervalSince1970) run=\(run) +\(elapsed)ms \(detail.prefix(1024))"
        let defaults = UserDefaults.standard
        var entries = defaults.stringArray(forKey: eventsKey) ?? []
        entries.append(line)
        defaults.set(Array(entries.suffix(500)), forKey: eventsKey)
    }

    static func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (UserDefaults.standard.stringArray(forKey: eventsKey) ?? []).joined(separator: "\n")
    }
}
