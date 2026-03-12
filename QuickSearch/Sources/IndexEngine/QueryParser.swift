// QueryParser.swift — Parses raw query text into a SearchQuery.
//
// PRD §8.1 / §8.2 syntax:
//   ext:pdf              → extension filter (single)
//   ext:zip,rar,7z       → extension filter (comma-separated list)
//   size:>50MB           → size > 50_000_000 bytes
//   size:<100KB          → size < 100_000 bytes
//   size:1MB..1GB        → size BETWEEN 1_000_000 AND 1_000_000_000
//   dm:>2026-01-01       → mod_time_ns > start-of-day (UTC)
//   dm:2026-01-01..2026-03-01 → mod_time_ns BETWEEN ...
//   path:Desktop         → rel_path contains "Desktop"
//   file:                → is_dir = 0
//   folder:              → is_dir = 1
//   "multi word"         → quoted phrase keyword
//   *.pdf                → wildcard name pattern
//   Everything else      → keyword term (AND-combined)

import Foundation

public struct QueryParser {

    public init() {}

    /// Parse `text` into a `SearchQuery`. Returns an empty query for blank input.
    public func parse(_ text: String) -> SearchQuery {
        var query = SearchQuery()
        let tokens = tokenize(text)

        var keywordParts: [String] = []

        for token in tokens {
            let lower = token.lowercased()

            if lower == "file:" {
                query.objectType = .fileOnly

            } else if lower == "folder:" {
                query.objectType = .folderOnly

            } else if lower.hasPrefix("ext:") {
                let value = String(token.dropFirst(4))
                let exts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                query.extensions.append(contentsOf: exts.filter { !$0.isEmpty })

            } else if lower.hasPrefix("size:") {
                let value = String(token.dropFirst(5))
                query.sizeFilter = parseSizeFilter(value)

            } else if lower.hasPrefix("dm:") {
                let value = String(token.dropFirst(3))
                query.dateFilter = parseDateFilter(value)

            } else if lower.hasPrefix("path:") {
                let value = String(token.dropFirst(5))
                // Strip surrounding quotes if present.
                query.pathKeyword = stripQuotes(value)

            } else if !token.isEmpty {
                keywordParts.append(stripQuotes(token))
            }
        }

        query.keyword = keywordParts.joined(separator: " ")
        return query
    }

    // MARK: - Tokenization

    /// Split by whitespace while respecting double-quoted strings.
    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for ch in text {
            if ch == "\"" {
                if inQuotes {
                    current.append(ch)   // include closing quote
                    tokens.append(current)
                    current = ""
                    inQuotes = false
                } else {
                    inQuotes = true
                    current.append(ch)  // include opening quote
                }
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func stripQuotes(_ s: String) -> String {
        var result = s
        if result.hasPrefix("\"") { result.removeFirst() }
        if result.hasSuffix("\"") { result.removeLast() }
        return result
    }

    // MARK: - Size filter parsing

    /// Parses: `>50MB`, `<100KB`, `50MB..1GB`, `500000` (raw bytes)
    private func parseSizeFilter(_ s: String) -> SearchQuery.SizeFilter? {
        if let range = parseRange(s, parser: parseBytes) {
            return SearchQuery.SizeFilter(min: range.lower, max: range.upper)
        }
        if s.hasPrefix(">") {
            guard let v = parseBytes(String(s.dropFirst())) else { return nil }
            return SearchQuery.SizeFilter(min: v + 1, max: nil)
        }
        if s.hasPrefix(">=") {
            guard let v = parseBytes(String(s.dropFirst(2))) else { return nil }
            return SearchQuery.SizeFilter(min: v, max: nil)
        }
        if s.hasPrefix("<") {
            guard let v = parseBytes(String(s.dropFirst())) else { return nil }
            return SearchQuery.SizeFilter(min: nil, max: v - 1)
        }
        if s.hasPrefix("<=") {
            guard let v = parseBytes(String(s.dropFirst(2))) else { return nil }
            return SearchQuery.SizeFilter(min: nil, max: v)
        }
        if let v = parseBytes(s) {
            return SearchQuery.SizeFilter(min: v, max: v)
        }
        return nil
    }

    /// Parse a byte count with optional unit suffix (KB, MB, GB, TB, B, or raw).
    private func parseBytes(_ s: String) -> Int64? {
        let upper = s.uppercased()
        let units: [(suffix: String, factor: Int64)] = [
            ("TB", 1_000_000_000_000),
            ("GB", 1_000_000_000),
            ("MB", 1_000_000),
            ("KB", 1_000),
            ("B",  1),
        ]
        for (suffix, factor) in units {
            if upper.hasSuffix(suffix) {
                let numStr = String(upper.dropLast(suffix.count))
                if let n = Double(numStr) { return Int64(n * Double(factor)) }
                return nil
            }
        }
        return Int64(s)
    }

    // MARK: - Date filter parsing

    /// Parses: `>2026-01-01`, `<2026-06-01`, `2026-01-01..2026-03-01`
    private func parseDateFilter(_ s: String) -> SearchQuery.DateFilter? {
        if let range = parseRange(s, parser: parseDateNs) {
            return SearchQuery.DateFilter(minNs: range.lower, maxNs: range.upper)
        }
        if s.hasPrefix(">") {
            guard let v = parseDateNs(String(s.dropFirst())) else { return nil }
            return SearchQuery.DateFilter(minNs: v, maxNs: nil)
        }
        if s.hasPrefix("<") {
            guard let v = parseDateNs(String(s.dropFirst())) else { return nil }
            return SearchQuery.DateFilter(minNs: nil, maxNs: v)
        }
        if let v = parseDateNs(s) {
            // Exact day: from start-of-day to end-of-day
            return SearchQuery.DateFilter(minNs: v, maxNs: v + 86_400_000_000_000 - 1)
        }
        return nil
    }

    /// Parse ISO-8601 date string (yyyy-MM-dd) → start-of-day nanosecond timestamp.
    private func parseDateNs(_ s: String) -> Int64? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let date = fmt.date(from: s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    // MARK: - Generic range parser

    /// Parses `lowerStr..upperStr` into (lower, upper).
    private struct RangeBound<T> {
        let lower: T?
        let upper: T?
    }

    private func parseRange<T>(_ s: String, parser: (String) -> T?) -> RangeBound<T>? {
        guard let sep = s.range(of: "..") else { return nil }
        let lowerStr = String(s[s.startIndex ..< sep.lowerBound])
        let upperStr = String(s[sep.upperBound...])
        let lower = lowerStr.isEmpty ? nil : parser(lowerStr)
        let upper = upperStr.isEmpty ? nil : parser(upperStr)
        return RangeBound(lower: lower, upper: upper)
    }
}
