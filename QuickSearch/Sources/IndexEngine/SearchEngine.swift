// SearchEngine.swift — Executes search queries and returns paginated results.
//
// PRD §8.3: query execution with pagination.
//   - Keyword search via FTS5 MATCH (fast O(log n) lookup).
//   - Fallback to LIKE for wildcard patterns.
//   - Column filters applied as secondary predicates on the files table.
//   - Returns SearchResult with rows + totalCount for pagination UI.
//
// Thread safety: SearchEngine is a struct; all DB access runs on DatabaseManager's actor.

import Foundation
import Database

public struct SearchEngine {

    private let db: DatabaseManager
    private let parser = QueryParser()
    private let builder = QueryBuilder()

    public init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - Public API

    /// Parse `text` and run a paginated search.
    /// - Parameters:
    ///   - text: Raw query string from the user (e.g. `"report ext:pdf size:>1MB"`).
    ///   - sortField: Column to sort by (default: name).
    ///   - sortOrder: Ascending or descending (default: ascending).
    ///   - limit: Page size (default: 200).
    ///   - offset: Row offset for pagination (default: 0).
    /// - Returns: A `SearchResult` with matching rows and the total count.
    public func search(
        _ text: String,
        sortField: SearchSortField = .name,
        sortOrder: SearchSortOrder = .ascending,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> SearchResult {
        let query = parser.parse(text)
        return try await execute(query: query, sortField: sortField,
                                 sortOrder: sortOrder, limit: limit, offset: offset)
    }

    /// Execute a pre-parsed `SearchQuery`.
    public func execute(
        query: SearchQuery,
        sortField: SearchSortField = .name,
        sortOrder: SearchSortOrder = .ascending,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> SearchResult {
        let startNs = DispatchTime.now().uptimeNanoseconds

        let selectBuilt = builder.buildSelect(
            query: query, sortField: sortField, sortOrder: sortOrder,
            limit: limit, offset: offset
        )
        let countBuilt = builder.buildCount(query: query)

        // Run on the DatabaseManager actor (shared connection, no re-entrancy issues).
        let rows = try await db.queryRows(
            sql: selectBuilt.sql,
            binders: { stmt in try selectBuilt.bind(to: stmt) },
            mapper: { stmt in
                SearchRow(
                    id:         stmt.columnInt64(0),
                    fullPath:   stmt.columnText(1) ?? "",
                    name:       stmt.columnText(2) ?? "",
                    fileExt:    stmt.columnText(3) ?? "",
                    size:       stmt.columnInt64(4),
                    modTimeNs:  stmt.columnInt64(5),
                    isDir:      stmt.columnInt64(6) != 0,
                    inode:      UInt64(bitPattern: stmt.columnInt64(7)),
                    mountPath:  stmt.columnText(8) ?? "",
                    volumeName: stmt.columnText(9) ?? ""
                )
            }
        )

        let total = try await db.queryCount(
            sql: countBuilt.sql,
            binders: { stmt in try countBuilt.bind(to: stmt) }
        )

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000

        return SearchResult(rows: rows, totalCount: total, queryMs: elapsedMs)
    }
}
