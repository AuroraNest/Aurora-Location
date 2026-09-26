import Foundation

@main struct DiagnosticLogCheck {
    static func main() {
        let defaults = UserDefaults.standard
        let keys = [DiagnosticLog.enabledKey, DiagnosticLog.eventsKey, "locationDebugEvents"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }

        precondition(!DiagnosticLog.enabled, "All builds must default to diagnostics off")
        var materialized = 0
        func detail(_ index: Int) -> String {
            materialized += 1
            return "maintenanceSet sample=\(index) enabled=true auth=4 target=true"
        }
        DiagnosticLog.begin("disabled")
        for index in 0..<600 { DiagnosticLog.event(detail(index)) }
        precondition(materialized == 0, "Disabled diagnostics must not construct event strings")
        precondition(defaults.object(forKey: DiagnosticLog.eventsKey) == nil)

        defaults.set(true, forKey: DiagnosticLog.enabledKey)
        DiagnosticLog.begin("enabled")
        precondition(DiagnosticLog.report().split(separator: "\n").count == 2)
        for index in 0..<600 { DiagnosticLog.event(detail(index)) }
        let entries = defaults.stringArray(forKey: DiagnosticLog.eventsKey) ?? []
        precondition(materialized == 600 && entries.count == 500)
        precondition(entries.first?.contains("sample=100 ") == true)
        precondition(entries.last?.contains("sample=599 ") == true)

        defaults.set(false, forKey: DiagnosticLog.enabledKey)
        DiagnosticLog.begin("disabled-again")
        for index in 0..<600 { DiagnosticLog.event(detail(index)) }
        precondition(materialized == 600)
        precondition(defaults.stringArray(forKey: DiagnosticLog.eventsKey) == entries,
                     "Turning diagnostics off must retain existing records without adding new ones")
        defaults.set(["legacy event"], forKey: "locationDebugEvents")
        DiagnosticLog.clear()
        precondition(DiagnosticLog.report().isEmpty)
        precondition(defaults.object(forKey: "locationDebugEvents") == nil)
        print("PASS: default off, lazy disabled events, manual on/off, 500-event limit, export and clear")

        // Synthetic event work only; this does not measure iPhone battery or physical disk writes.
        let samples = 600
        func measure(enabled: Bool) -> Double {
            defaults.set(enabled, forKey: DiagnosticLog.enabledKey)
            DiagnosticLog.clear()
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<samples { DiagnosticLog.event(detail(index)) }
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
        let on = (0..<3).map { _ in measure(enabled: true) }.sorted()[1]
        let off = (0..<3).map { _ in measure(enabled: false) }.sorted()[1]
        print(String(format: "BENCH: %d events, median of 3, on=%.3f ms off=%.3f ms", samples, on, off))
        print("COUNTS: on=600 event materializations and 600 history set calls; off=0 and 0")
    }
}
