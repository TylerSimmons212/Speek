import Foundation

/// Deterministic spoken-number → digit conversion for dictation cleanup.
/// Examples it handles:
///   "twenty twenty four" → "2024"
///   "one hundred twenty three" → "123"
///   "may fifth" → "May 5"
///   "five hundred dollars" → "$500"
///   "three point one four" → "3.14"
///   "first" / "second" / "twenty first" → "1st" / "2nd" / "21st"
///
/// Limited scope — designed to handle the common dictation cases, not arbitrary
/// English number parsing. Anything ambiguous is left alone for the LLM polish
/// stage (or simply for the user to fix).
enum NumberFormatStage {
    static func run(_ input: String) -> String {
        var s = input
        // Date and compound-ordinal handling runs first so word-forms like
        // "may fifth" / "twenty first" aren't consumed by the cardinal pass.
        s = formatDates(s)
        s = formatCompoundOrdinals(s)
        s = collapseSpokenNumbers(s)
        s = formatCurrency(s)
        return s
    }

    // MARK: - Spoken numbers

    /// Words that name a value, in order of precedence.
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000
    ]

    private static let numberWordSet: Set<String> = {
        var s = Set<String>()
        s.formUnion(units.keys)
        s.formUnion(tens.keys)
        s.formUnion(scales.keys)
        s.insert("and")        // "one hundred and twenty"
        s.insert("point")      // "three point one four"
        return s
    }()

    private static func collapseSpokenNumbers(_ input: String) -> String {
        // Match a run of 2+ number-words separated by spaces. Single-word units
        // ("four", "ten") are intentionally left alone — style convention is to
        // write small standalone numbers as words.
        let word = "(?:" + numberWordSet.joined(separator: "|") + ")"
        let pattern = "(?i)\\b\(word)(?:\\s+\(word))+\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return replaceMatches(in: input, regex: regex) { match, source in
            let text = String(source[Range(match.range, in: source)!])
            let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return parseNumberWords(words) ?? text
        }
    }

    /// Parses a sequence of number-words into a single numeric string. Returns
    /// nil if the sequence doesn't form a coherent number (e.g. just "and").
    private static func parseNumberWords(_ words: [String]) -> String? {
        // Strip leading/trailing "and"s.
        var ws = words
        while ws.first == "and" { ws.removeFirst() }
        while ws.last == "and" { ws.removeLast() }
        guard !ws.isEmpty else { return nil }

        // "twenty twenty four" or "nineteen ninety nine" → year style.
        if let year = parseYearStyle(ws) { return String(year) }

        // "point" → decimal portion.
        if let dotIdx = ws.firstIndex(of: "point") {
            let intPart = Array(ws[..<dotIdx])
            let fracPart = Array(ws[(dotIdx + 1)...])
            guard let intVal = parseCardinal(intPart) else { return nil }
            // Each fractional word must be a single digit unit.
            var fracStr = ""
            for w in fracPart {
                if let v = units[w], v < 10 { fracStr.append(String(v)) }
                else { return nil }
            }
            return fracStr.isEmpty ? String(intVal) : "\(intVal).\(fracStr)"
        }

        guard let val = parseCardinal(ws) else { return nil }
        return String(val)
    }

    /// Year style: two two-digit decades spoken back-to-back ("twenty twenty
    /// four"). Requires both halves to be at least 10 so "twenty four" is left
    /// as the cardinal 24 (not interpreted as the year 2004).
    private static func parseYearStyle(_ words: [String]) -> Int? {
        guard words.count == 2 || words.count == 3 else { return nil }
        for split in 1..<words.count {
            let left = Array(words[..<split])
            let right = Array(words[split...])
            if let l = parseCardinal(left), let r = parseCardinal(right),
               l >= 10 && l <= 99 && r >= 10 && r <= 99 {
                return l * 100 + r
            }
        }
        return nil
    }

    /// Classic English-number parser, sums by scale.
    private static func parseCardinal(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        var total = 0
        var current = 0
        var sawAny = false
        for word in words {
            if word == "and" { continue }
            if let u = units[word] { current += u; sawAny = true }
            else if let t = tens[word] { current += t; sawAny = true }
            else if word == "hundred" {
                if current == 0 { current = 1 }
                current *= 100
                sawAny = true
            } else if let s = scales[word] {
                if current == 0 { current = 1 }
                total += current * s
                current = 0
                sawAny = true
            } else {
                return nil
            }
        }
        return sawAny ? total + current : nil
    }

    // MARK: - Dates

    private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]
    private static let ordinalNames: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30
    ]
    private static let tensOrdinal: [String: Int] = [
        "twenty": 20, "thirty": 30
    ]

    /// "May fifth" → "May 5", "October twenty first" → "October 21".
    private static func formatDates(_ input: String) -> String {
        let monthPattern = monthNames.joined(separator: "|")
        let ordinalPattern = ordinalNames.keys.joined(separator: "|")
        let tensPattern = tensOrdinal.keys.joined(separator: "|")
        // Two cases: <month> <tens> <ordinal>, or <month> <ordinal>.
        let pattern2 = "(?i)\\b(\(monthPattern))\\s+(\(tensPattern))\\s+(\(ordinalPattern))\\b"
        let pattern1 = "(?i)\\b(\(monthPattern))\\s+(\(ordinalPattern))\\b"
        var s = input
        if let regex = try? NSRegularExpression(pattern: pattern2) {
            s = replaceMatches(in: s, regex: regex) { match, source in
                let month = String(source[Range(match.range(at: 1), in: source)!]).capitalized
                let tensWord = String(source[Range(match.range(at: 2), in: source)!]).lowercased()
                let ordWord = String(source[Range(match.range(at: 3), in: source)!]).lowercased()
                guard let tens = tensOrdinal[tensWord], let ord = ordinalNames[ordWord] else {
                    return String(source[Range(match.range, in: source)!])
                }
                return "\(month) \(tens + ord)"
            }
        }
        if let regex = try? NSRegularExpression(pattern: pattern1) {
            s = replaceMatches(in: s, regex: regex) { match, source in
                let month = String(source[Range(match.range(at: 1), in: source)!]).capitalized
                let ordWord = String(source[Range(match.range(at: 2), in: source)!]).lowercased()
                guard let ord = ordinalNames[ordWord] else {
                    return String(source[Range(match.range, in: source)!])
                }
                return "\(month) \(ord)"
            }
        }
        return s
    }

    // MARK: - Currency

    /// "five hundred dollars" / "fifty dollars" → "$500" / "$50".
    private static func formatCurrency(_ input: String) -> String {
        // After collapseSpokenNumbers, numbers are already digits.
        let pattern = "(?i)\\b(\\d+(?:\\.\\d+)?)\\s+dollars?\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return replaceMatches(in: input, regex: regex) { match, source in
            let value = String(source[Range(match.range(at: 1), in: source)!])
            return "$\(value)"
        }
    }

    // MARK: - Ordinals

    /// Only compound ordinals like "twenty first" → "21st". Standalone forms
    /// ("first", "second") are deliberately left as words to match English prose
    /// convention; the user can opt into digit forms via custom replacements.
    private static func formatCompoundOrdinals(_ input: String) -> String {
        let tensPattern = tensOrdinal.keys.joined(separator: "|")
        let ordPattern = ordinalNames.keys.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?i)\\b(\(tensPattern))\\s+(\(ordPattern))\\b") else {
            return input
        }
        return replaceMatches(in: input, regex: regex) { match, source in
            let tensWord = String(source[Range(match.range(at: 1), in: source)!]).lowercased()
            let ordWord = String(source[Range(match.range(at: 2), in: source)!]).lowercased()
            guard let tens = tensOrdinal[tensWord], let ord = ordinalNames[ordWord] else {
                return String(source[Range(match.range, in: source)!])
            }
            return "\(tens + ord)" + ordinalSuffix(tens + ord)
        }
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        let mod100 = n % 100
        if (11...13).contains(mod100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    // MARK: - Helpers

    private static func replaceMatches(
        in source: String,
        regex: NSRegularExpression,
        transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        let nsRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: nsRange)
        guard !matches.isEmpty else { return source }
        var result = ""
        var lastEnd = source.startIndex
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            result += source[lastEnd..<range.lowerBound]
            result += transform(match, source)
            lastEnd = range.upperBound
        }
        result += source[lastEnd...]
        return result
    }
}
