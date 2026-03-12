// SearchQuery.swift — Parsed search query data model.
//
// PRD §8.1: syntax grammar for the query engine.
// All fields are value types; SearchQuery is Sendable.

import Foundation

// MARK: - SearchQuery

public struct SearchQuery: Sendable {

    /// Plain keyword(s) for name search. Multiple words are AND-combined.
    /// May contain FTS5 terms or wildcard patterns (detected by `hasWildcard`).
    public var keyword: String = ""

    /// Extension whitelist from `ext:` operator (lowercased, without dot).
    public var extensions: [String] = []

    /// Size filter from `size:` operator.
    public var sizeFilter: SizeFilter? = nil

    /// Modification-time filter from `dm:` operator.
    public var dateFilter: DateFilter? = nil

    /// Path keyword from `path:` operator. Matched as substring of rel_path.
    public var pathKeyword: String = ""

    /// Object type filter from `file:` / `folder:` operators.
    public var objectType: ObjectType = .all

    /// True when keyword contains `*` or `?` wildcard characters.
    public var hasWildcard: Bool { keyword.contains("*") || keyword.contains("?") }

    /// True when the query has at least one search criterion.
    public var isEmpty: Bool {
        keyword.isEmpty && extensions.isEmpty && sizeFilter == nil
            && dateFilter == nil && pathKeyword.isEmpty && objectType == .all
    }

    public init() {}

    // MARK: - Nested types

    public enum ObjectType: Sendable {
        case all
        case fileOnly
        case folderOnly
    }

    /// Size range filter. Both bounds are in bytes; nil = unbounded.
    public struct SizeFilter: Sendable {
        public let min: Int64?   // nil = no lower bound
        public let max: Int64?   // nil = no upper bound

        public init(min: Int64?, max: Int64?) {
            self.min = min
            self.max = max
        }
    }

    /// Modification-time range filter. Both bounds are nanosecond timestamps; nil = unbounded.
    public struct DateFilter: Sendable {
        public let minNs: Int64?  // nil = no lower bound
        public let maxNs: Int64?  // nil = no upper bound

        public init(minNs: Int64?, maxNs: Int64?) {
            self.minNs = minNs
            self.maxNs = maxNs
        }
    }
}

// MARK: - SearchRow

/// A single row returned by a search query.
public struct SearchRow: Sendable {
    public let id: Int64
    public let fullPath: String       // mount_path (trimmed) + rel_path
    public let name: String
    public let fileExt: String
    public let size: Int64
    public let modTimeNs: Int64
    public let isDir: Bool
    public let inode: UInt64
    public let mountPath: String
    public let volumeName: String
}

// MARK: - SearchResult

public struct SearchResult: Sendable {
    public let rows: [SearchRow]
    public let totalCount: Int        // total matching rows (ignoring LIMIT/OFFSET)
    public let queryMs: Double        // wall time for the query in milliseconds
}

// MARK: - Sort

public enum SearchSortField: String, Sendable, CaseIterable {
    case name
    case size
    case modTime = "mod_time"
    case path
}

public enum SearchSortOrder: Sendable {
    case ascending
    case descending
}
