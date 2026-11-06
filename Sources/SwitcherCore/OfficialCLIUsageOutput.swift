import Foundation

/// Reads only the native /usage result, never model cost/token counters.
/// Unknown formats remain unknown. Raw output is never persisted here.
public enum OfficialCLIUsageOutput {
    public enum Failure: Error { case commandFailed, invalidReading }
    public static func read(_ output: String, identity: CLIIdentity, observedAt: Date) throws -> OfficialCLIUsageCache? {
        guard identity.isComplete else { throw Failure.invalidReading }
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["type"] as? String == "result" else { return nil }
            guard let errorFlag = object["is_error"] as? Bool else { throw Failure.invalidReading }
            if errorFlag { throw Failure.commandFailed }
            guard let result = object["result"] as? String else { return nil }
            text = result
        }
        text = text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let lower = text.lowercased()
        if ["login expired", "not logged in", "please run /login", "unauthorized", "forbidden",
            "failed to load usage", "temporarily unavailable", "unknown skill", "unknown command"].contains(where: lower.contains) {
            throw Failure.commandFailed
        }
        let regex = try NSRegularExpression(pattern: #"^Current (session|week(?: \(([^)]+)\))?):\s*([0-9]+(?:\.[0-9]+)?)%\s+used(?:\s*[·•]\s*resets\s+(.+))?\s*$"#,
                                            options: [.anchorsMatchLines, .caseInsensitive])
        let source = text as NSString
        var windows: [String: OfficialUsageWindow] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            func group(_ i: Int) -> String? { match.range(at:i).location == NSNotFound ? nil : source.substring(with:match.range(at:i)) }
            let label = group(1)!.lowercased(), scope = group(2)?.lowercased()
            let key: String
            if label == "session" { key = "session" }
            else if scope == nil || scope == "all models" { key = "weekly" }
            else if scope == "opus" || scope == "opus only" { key = "opus" }
            else { continue }
            guard let used = Double(group(3)!), used.isFinite, (0...100).contains(used) else { throw Failure.invalidReading }
            let value = OfficialUsageWindow(used: used, resetsAt: group(4).flatMap {
                reset($0, now: observedAt, span: key == "session" ? 5 * 3600 : 7 * 86400)
            })
            if let previous = windows[key], previous != value { throw Failure.invalidReading }
            windows[key] = value
        }
        guard windows["session"] != nil || windows["weekly"] != nil else { return nil }
        return OfficialCLIUsageCache(identity: identity, fetchedAt: observedAt,
                                     session: windows["session"], weekly: windows["weekly"], weeklyOpus: windows["opus"])
    }
    private static func reset(_ raw: String, now: Date, span: TimeInterval) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        var zone = TimeZone.current
        if text.hasSuffix(")"), let index = text.lastIndex(of: "(") {
            guard let named = TimeZone(identifier: String(text[text.index(after:index)..<text.index(before:text.endIndex)])) else { return nil }
            zone = named; text = String(text[..<index]).trimmingCharacters(in:.whitespaces)
        }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = zone
        for format in ["MMM d, yyyy 'at' h:mma", "MMM d, yyyy 'at' ha", "MMM d 'at' h:mma", "MMM d 'at' ha", "h:mma", "ha"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.calendar = calendar; formatter.timeZone = zone; formatter.dateFormat = format
            formatter.defaultDate = now; formatter.isLenient = false
            guard let parsed = formatter.date(from: text) else { continue }
            var date = parsed
            if format == "h:mma" || format == "ha" {
                let parts = calendar.dateComponents([.hour,.minute], from: parsed)
                guard let today = calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: 0, of: now) else { return nil }
                date = today
                if date < now.addingTimeInterval(-60) { date = calendar.date(byAdding:.day,value:1,to:date) ?? date }
            } else if !format.contains("yyyy") {
                var parts = calendar.dateComponents([.month,.day,.hour,.minute], from:parsed)
                parts.year = calendar.component(.year,from:now)
                guard let currentYear = calendar.date(from:parts) else { return nil }
                date = currentYear
                if date < now.addingTimeInterval(-86400) { date = calendar.date(byAdding:.year,value:1,to:date) ?? date }
            }
            // A date outside this window cannot safely be inferred from abbreviated text.
            if date >= now.addingTimeInterval(-86400), date <= now.addingTimeInterval(span + 7200) { return date }
        }
        return nil
    }
}
