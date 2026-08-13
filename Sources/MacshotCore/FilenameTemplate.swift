import Foundation

/// ShareX-style filename token expansion (PRD §6.7).
enum FilenameTemplate {
    struct Context {
        var date = Date()
        var windowTitle: String?
        var appName: String?
        var host = ProcessInfo.processInfo.hostName
        var user = NSUserName()
        /// Pre-resolved counter value; nil renders as 1 (validation/preview).
        var counter: Int?
        var counterPadding = 4
        var uuidProvider: () -> String = { UUID().uuidString }
        var randomProvider: (Int) -> String = { FilenameTemplate.randomAlphanumeric($0) }
    }

    /// Token names ordered longest-first so `%mo` never half-matches `%ms`.
    private static let tokenNames = [
        "counter", "window", "host", "user", "uuid",
        "app", "rand", "mo", "mi", "ms", "y", "d", "h", "s"
    ]

    static func expand(_ template: String, context: Context) -> String {
        let parts = dateParts(from: context.date)
        var out = ""
        var idx = template.startIndex
        while idx < template.endIndex {
            guard template[idx] == "%" else {
                out.append(template[idx])
                idx = template.index(after: idx)
                continue
            }
            let rest = template[template.index(after: idx)...]
            if let (replacement, consumed) = matchToken(rest, context: context, dateParts: parts) {
                out += replacement
                idx = template.index(idx, offsetBy: 1 + consumed)
            } else {
                out.append("%")
                idx = template.index(after: idx)
            }
        }
        return out
    }

    /// A template is valid when it expands to a non-empty name against
    /// synthetic values (PRD: settings UI rejects templates yielding empty strings).
    static func isValid(_ template: String) -> Bool {
        var context = Context()
        context.windowTitle = "Window"
        context.appName = "App"
        let expanded = expand(template, context: context)
        return !expanded.isEmpty && expanded != extensionSuffix(of: expanded)
    }

    /// Sanitize per PRD: alphanumerics and `-_` kept, everything else becomes `_`.
    static func sanitize(_ raw: String) -> String {
        let allowed: Set<Character> = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        )
        return String(raw.map { allowed.contains($0) ? $0 : "_" })
    }

    static func randomAlphanumeric(_ count: Int) -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<count).compactMap { _ in alphabet.randomElement() })
    }

    /// Known image extension (with leading dot) at the end of the name, or "".
    static func extensionSuffix(of name: String) -> String {
        let knownExtensions = ["png", "jpg", "jpeg", "heic"]
        let lower = name.lowercased()
        for ext in knownExtensions where lower.hasSuffix(".\(ext)") {
            return String(name.suffix(ext.count + 1))
        }
        return ""
    }

    // MARK: - Internals

    private struct DateParts {
        let y: String, mo: String, d: String, h: String, mi: String, s: String, ms: String
    }

    private static func dateParts(from date: Date) -> DateParts {
        let cal = Calendar.current
        let c = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        func pad(_ value: Int, _ width: Int) -> String {
            let raw = String(value)
            return raw.count >= width ? raw : String(repeating: "0", count: width - raw.count) + raw
        }
        return DateParts(
            y: pad(c.year ?? 0, 4),
            mo: pad(c.month ?? 0, 2),
            d: pad(c.day ?? 0, 2),
            h: pad(c.hour ?? 0, 2),
            mi: pad(c.minute ?? 0, 2),
            s: pad(c.second ?? 0, 2),
            // Calendar round-trips nanoseconds through Double; round (and clamp)
            // so 6_999_999 ns reads as 007, not 006.
            ms: pad(min(999, ((c.nanosecond ?? 0) + 500_000) / 1_000_000), 3)
        )
    }

    /// Returns (replacement, characters consumed after the %) or nil if no token matches.
    private static func matchToken(
        _ rest: Substring,
        context: Context,
        dateParts: DateParts
    ) -> (String, Int)? {
        for name in tokenNames where rest.hasPrefix(name) {
            if name == "rand" {
                // %rand:N — N decimal digits required; otherwise not a token.
                let afterRand = rest.dropFirst(4)
                guard afterRand.first == ":" else { return nil }
                let digits = afterRand.dropFirst().prefix(while: \.isNumber)
                guard let n = Int(digits), n > 0 else { return nil }
                return (context.randomProvider(n), 4 + 1 + digits.count)
            }
            let replacement: String
            switch name {
            case "counter":
                let value = context.counter ?? 1
                let raw = String(value)
                let width = max(1, context.counterPadding)
                replacement = raw.count >= width
                    ? raw
                    : String(repeating: "0", count: width - raw.count) + raw
            case "window": replacement = sanitize(context.windowTitle ?? "")
            case "app": replacement = sanitize(context.appName ?? "")
            case "host": replacement = sanitize(context.host)
            case "user": replacement = sanitize(context.user)
            case "uuid": replacement = context.uuidProvider()
            case "y": replacement = dateParts.y
            case "mo": replacement = dateParts.mo
            case "d": replacement = dateParts.d
            case "h": replacement = dateParts.h
            case "mi": replacement = dateParts.mi
            case "s": replacement = dateParts.s
            case "ms": replacement = dateParts.ms
            default: return nil
            }
            return (replacement, name.count)
        }
        return nil
    }
}
