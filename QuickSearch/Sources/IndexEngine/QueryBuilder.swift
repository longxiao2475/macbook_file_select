// QueryBuilder.swift — Converts a SearchQuery into parameterised SQL.
//
// PRD §8.3:
//   - Keyword → FTS5 MATCH (no wildcards) or LIKE (wildcards).
//   - Filters (ext/size/dm/path/type) → index-backed column predicates.
//   - Sort whitelist: name, size, mod_time, path (PRD §8.3 item 4).
//   - Pagination: LIMIT ? OFFSET ? with a separate COUNT(*) query.
//   - All values bound via parameterised binding; no string interpolation in WHERE.
//
// SQL query shape (FTS path):
//   SELECT f.id,
//          rtrim(v.mount_path, '/') || f.rel_path AS full_path,
//          f.name, f.file_ext, f.size, f.mod_time_ns, f.is_dir, f.inode,
//          v.mount_path, v.volume_name
//   FROM files_fts
//   JOIN files f ON files_fts.rowid = f.id
//   JOIN volumes v ON f.volume_id = v.id
//   WHERE files_fts MATCH ?
//     [AND f.file_ext IN (...)]
//     [AND f.size BETWEEN ? AND ?]
//     [AND f.mod_time_ns > ?]
//     [AND f.is_dir = ?]
//     [AND f.rel_path LIKE ?]
//   ORDER BY rank [, f.name]
//   LIMIT ? OFFSET ?
//
// SQL query shape (scan path, no keyword):
//   SELECT ... FROM files f JOIN volumes v ...
//   WHERE [column conditions]
//   ORDER BY f.<sortField> [ASC|DESC]
//   LIMIT ? OFFSET ?

import Foundation
import Database

// MARK: - BuiltSQL

/// A fully-constructed SQL string with its binder closure.
/// Binder receives a `Statement` at runtime and binds all `?` parameters in order.
public struct BuiltSQL: Sendable {
    public let sql: String
    /// Sorted list of parameters in the order they appear in `?` placeholders.
    public let parameters: [SQLParameter]

    public func bind(to stmt: Statement) throws {
        for (i, param) in parameters.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .text(let s): try stmt.bind(text: s, at: idx)
            case .int(let n):  try stmt.bind(int: n, at: idx)
            }
        }
    }
}

public enum SQLParameter: Sendable {
    case text(String)
    case int(Int64)
}

// MARK: - QueryBuilder

public struct QueryBuilder {

    private static let selectColumns = """
        f.id,
        rtrim(v.mount_path, '/') || f.rel_path AS full_path,
        f.name, f.file_ext, f.size, f.mod_time_ns, f.is_dir, f.inode,
        v.mount_path, v.volume_name
        """

    /// Sort field → SQL column expression (whitelist).
    private static let sortColumnMap: [SearchSortField: String] = [
        .name:    "f.name",
        .size:    "f.size",
        .modTime: "f.mod_time_ns",
        .path:    "full_path",
    ]

    public init() {}

    // MARK: - Public API

    /// Build the paginated SELECT query.
    public func buildSelect(
        query: SearchQuery,
        sortField: SearchSortField = .name,
        sortOrder: SearchSortOrder = .ascending,
        limit: Int,
        offset: Int
    ) -> BuiltSQL {
        var params: [SQLParameter] = []
        let whereClause = buildWhere(query: query, params: &params)
        let orderClause = buildOrder(sortField: sortField, sortOrder: sortOrder, useFTS: !query.keyword.isEmpty && !query.hasWildcard)
        let from = buildFrom(query: query)

        var sql = "SELECT \(QueryBuilder.selectColumns) FROM \(from) \(whereClause) \(orderClause)"
        sql += " LIMIT ? OFFSET ?"
        params.append(.int(Int64(limit)))
        params.append(.int(Int64(offset)))

        return BuiltSQL(sql: sql, parameters: params)
    }

    /// Build the COUNT(*) query (same WHERE, no pagination/sort).
    public func buildCount(query: SearchQuery) -> BuiltSQL {
        var params: [SQLParameter] = []
        let whereClause = buildWhere(query: query, params: &params)
        let from = buildFrom(query: query)

        let sql = "SELECT COUNT(*) FROM \(from) \(whereClause)"
        return BuiltSQL(sql: sql, parameters: params)
    }

    // MARK: - FROM clause

    private func buildFrom(query: SearchQuery) -> String {
        let hasKeyword = !query.keyword.isEmpty
        if hasKeyword && !query.hasWildcard {
            // FTS path: join through files_fts for MATCH support.
            return "files_fts JOIN files f ON files_fts.rowid = f.id JOIN volumes v ON f.volume_id = v.id"
        } else {
            // Scan path: direct files table scan.
            return "files f JOIN volumes v ON f.volume_id = v.id"
        }
    }

    // MARK: - WHERE clause

    private func buildWhere(query: SearchQuery, params: inout [SQLParameter]) -> String {
        var predicates: [String] = []

        // ── Keyword ──────────────────────────────────────────────────────────
        if !query.keyword.isEmpty {
            if query.hasWildcard {
                // Wildcard: convert * → % and ? → _ for LIKE on the name column.
                let pattern = wildcardToLike(query.keyword)
                predicates.append("f.name LIKE ?")
                params.append(.text(pattern))
            } else {
                // FTS5 MATCH with phrase quoting.
                // Multiple space-separated words → AND-combined phrases.
                let ftsExpr = query.keyword
                    .split(separator: " ")
                    .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                    .joined(separator: " AND ")
                predicates.append("files_fts MATCH ?")
                params.append(.text(ftsExpr))
            }
        }

        // ── Extension ────────────────────────────────────────────────────────
        if !query.extensions.isEmpty {
            let placeholders = query.extensions.map { _ in "?" }.joined(separator: ",")
            predicates.append("f.file_ext IN (\(placeholders))")
            for ext in query.extensions { params.append(.text(ext)) }
        }

        // ── Size ─────────────────────────────────────────────────────────────
        if let sf = query.sizeFilter {
            if let mn = sf.min, let mx = sf.max {
                predicates.append("f.size BETWEEN ? AND ?")
                params.append(.int(mn)); params.append(.int(mx))
            } else if let mn = sf.min {
                predicates.append("f.size >= ?")
                params.append(.int(mn))
            } else if let mx = sf.max {
                predicates.append("f.size <= ?")
                params.append(.int(mx))
            }
        }

        // ── Date ─────────────────────────────────────────────────────────────
        if let df = query.dateFilter {
            if let mn = df.minNs, let mx = df.maxNs {
                predicates.append("f.mod_time_ns BETWEEN ? AND ?")
                params.append(.int(mn)); params.append(.int(mx))
            } else if let mn = df.minNs {
                predicates.append("f.mod_time_ns >= ?")
                params.append(.int(mn))
            } else if let mx = df.maxNs {
                predicates.append("f.mod_time_ns <= ?")
                params.append(.int(mx))
            }
        }

        // ── Path ─────────────────────────────────────────────────────────────
        if !query.pathKeyword.isEmpty {
            predicates.append("f.rel_path LIKE ?")
            // Escape LIKE special chars in the user value, then wrap with %.
            let escaped = likeEscape(query.pathKeyword)
            params.append(.text("%\(escaped)%"))
        }

        // ── Object type ───────────────────────────────────────────────────────
        switch query.objectType {
        case .fileOnly:   predicates.append("f.is_dir = 0")
        case .folderOnly: predicates.append("f.is_dir = 1")
        case .all:        break
        }

        return predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
    }

    // MARK: - ORDER BY clause

    private func buildOrder(
        sortField: SearchSortField,
        sortOrder: SearchSortOrder,
        useFTS: Bool
    ) -> String {
        let dir = sortOrder == .ascending ? "ASC" : "DESC"
        let col = QueryBuilder.sortColumnMap[sortField] ?? "f.name"

        // For FTS, prepend `rank` so that best matches come first.
        if useFTS && sortField == .name {
            return "ORDER BY rank, \(col) \(dir)"
        }
        return "ORDER BY \(col) \(dir)"
    }

    // MARK: - Helpers

    /// Convert wildcard pattern (`*`, `?`) to SQL LIKE pattern (`%`, `_`).
    /// Escapes literal `%`, `_`, and `\` in the original pattern first.
    private func wildcardToLike(_ pattern: String) -> String {
        var result = ""
        for ch in pattern {
            switch ch {
            case "%":  result += "\\%"
            case "_":  result += "\\_"
            case "\\":  result += "\\\\"
            case "*":  result += "%"
            case "?":  result += "_"
            default:   result.append(ch)
            }
        }
        return result
    }

    /// Escape `%`, `_`, `\` in a LIKE value (for path:keyword wrapped in `%...%`).
    private func likeEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%",  with: "\\%")
            .replacingOccurrences(of: "_",  with: "\\_")
    }
}
