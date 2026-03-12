// main.swift — CLI for QuickSearch M1 Index Engine.
//
// Subcommands:
//   (default)  Scan and index a directory.
//   search     Query the index.
//
// Scan usage:
//   QuickSearch [path] [--db <path>] [--batch-size <n>]
//               [--priority-only] [--supplement] [--fast-scan]
//               [--exclude-dir <name>] ...
//
//   path             Directory to scan (default: $HOME)
//   --db             Database file (default: ~/.local/share/QuickSearch/index.db)
//   --batch-size     Override scanner batch size for A/B testing (default: 100000)
//   --priority-only  Index only priority extensions (docs/archives/images/video/audio)
//                    and skip common cache/build directories. Fastest initial scan.
//   --supplement     Fill files not yet indexed. Preserves existing records.
//   --fast-scan      Skip lstat() for regular files (DT_REG); records size=0, mtime=0.
//                    Requires --priority-only. NTFS fskit must return valid d_type.
//                    Run --supplement afterwards to fill in size/mtime metadata.
//   --exclude-dir    Exclude directory by name (repeatable). Applies in addition to
//                    built-in exclusion rules. Example: --exclude-dir Backup --exclude-dir old
//
// Search usage:
//   QuickSearch search "<query>" [--db <path>] [--limit <n>] [--offset <n>]
//               [--sort name|size|mod_time|path] [--desc]
//
//   <query>          Search expression, e.g.:
//                      "report"                  — name contains "report"
//                      "*.psd ext:psd"           — wildcard + ext filter
//                      "invoice ext:pdf size:>1MB dm:>2026-01-01"
//                      "path:Desktop file:"      — files in Desktop folder
//   --limit          Max results to show (default: 50)
//   --offset         Skip first N results (default: 0)
//   --sort           Sort field: name (default), size, mod_time, path
//   --desc           Sort descending (default: ascending)

import Foundation
import IndexEngine
import Database

// MARK: - Argument parsing

let defaultHome = FileManager.default.homeDirectoryForCurrentUser
let defaultScanPath = defaultHome.path
let defaultDBPath = defaultHome
    .appendingPathComponent(".local/share/QuickSearch/index.db").path

// Detect subcommand.
enum Subcommand { case index, search }
var subcommand: Subcommand = .index
var searchQuery: String = ""
var searchLimit: Int = 50
var searchOffset: Int = 0
var searchSortField: SearchSortField = .name
var searchSortDesc: Bool = false

var scanPath = defaultScanPath
var dbPath = defaultDBPath
var batchSizeOverride: Int? = nil
var scanMode: ScanMode = .full
var fastScan = false
var additionalExcludedDirs: [String] = []

var argIter = CommandLine.arguments.dropFirst().makeIterator()
// Peek at the first argument for subcommand detection.
if let first = argIter.next() {
    if first == "search" {
        subcommand = .search
        // First non-flag argument after "search" is the query string.
        if let q = argIter.next(), !q.hasPrefix("--") {
            searchQuery = q
        }
    } else if !first.hasPrefix("--") {
        scanPath = first
    } else {
        // It's a flag — process it below by falling through.
        switch first {
        case "--db":       if let n = argIter.next() { dbPath = n }
        case "--batch-size": if let n = argIter.next(), let v = Int(n) { batchSizeOverride = v }
        case "--priority-only": scanMode = .priorityOnly
        case "--supplement":    scanMode = .supplement
        case "--fast-scan":     fastScan = true
        case "--exclude-dir":   if let n = argIter.next() { additionalExcludedDirs.append(n) }
        default: break
        }
    }
}

while let arg = argIter.next() {
    switch arg {
    case "--db":
        if let next = argIter.next() { dbPath = next }
    case "--batch-size":
        if let next = argIter.next(), let n = Int(next) { batchSizeOverride = n }
    case "--priority-only":
        scanMode = .priorityOnly
    case "--supplement":
        scanMode = .supplement
    case "--fast-scan":
        fastScan = true
    case "--exclude-dir":
        if let next = argIter.next() { additionalExcludedDirs.append(next) }
    // Search-specific flags
    case "--limit":
        if let next = argIter.next(), let n = Int(next) { searchLimit = n }
    case "--offset":
        if let next = argIter.next(), let n = Int(next) { searchOffset = n }
    case "--sort":
        if let next = argIter.next() {
            searchSortField = SearchSortField(rawValue: next) ?? .name
        }
    case "--desc":
        searchSortDesc = true
    default:
        if !arg.hasPrefix("--") {
            if subcommand == .search && searchQuery.isEmpty { searchQuery = arg }
            else if subcommand == .index { scanPath = arg }
        }
    }
}

// MARK: - Search subcommand

if subcommand == .search {
    let exitCode: Int32 = await withCheckedContinuation { continuation in
        Task {
            do {
                if searchQuery.isEmpty {
                    fputs("Error: search requires a query string.\n", stderr)
                    fputs("Usage: QuickSearch search \"<query>\" [--db <path>] [--limit <n>]\n", stderr)
                    continuation.resume(returning: 1)
                    return
                }

                let dbURL = URL(fileURLWithPath: dbPath)
                let db = try await DatabaseManager(dbURL: dbURL)
                let engine = SearchEngine(db: db)

                let sortOrder: SearchSortOrder = searchSortDesc ? .descending : .ascending
                let result = try await engine.search(
                    searchQuery,
                    sortField: searchSortField,
                    sortOrder: sortOrder,
                    limit: searchLimit,
                    offset: searchOffset
                )

                // Print header
                let colWidth = 60
                func col(_ s: String, _ w: Int) -> String {
                    s.count <= w ? s + String(repeating: " ", count: w - s.count)
                                 : String(s.prefix(w - 1)) + "…"
                }
                print("\(col("Path", colWidth))  \(col("Size", 14))  \(col("Modified", 20))")
                print(String(repeating: "-", count: colWidth + 38))

                for row in result.rows {
                    let sizeStr = row.isDir ? "—" : formatSize(row.size)
                    let dateStr = formatDate(row.modTimeNs)
                    let path = row.fullPath
                    print("\(col(path, colWidth))  \(col(sizeStr, 14))  \(col(dateStr, 20))")
                }

                print("")
                print("Results: \(result.rows.count) of \(result.totalCount)  (query: \(String(format: "%.1f", result.queryMs))ms)")
                if searchOffset > 0 || result.totalCount > searchLimit + searchOffset {
                    let nextOffset = searchOffset + searchLimit
                    if nextOffset < result.totalCount {
                        print("  Next page: --offset \(nextOffset)")
                    }
                }

                continuation.resume(returning: 0)
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                continuation.resume(returning: 1)
            }
        }
    }
    exit(exitCode)
}

// MARK: - Index subcommand helpers (size/date formatting shared with search output)

func formatSize(_ bytes: Int64) -> String {
    if bytes == 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1000 && idx < units.count - 1 { value /= 1000; idx += 1 }
    return idx == 0 ? "\(Int(value)) \(units[idx])"
                    : String(format: "%.1f \(units[idx])", value)
}

func formatDate(_ ns: Int64) -> String {
    guard ns > 0 else { return "—" }
    let date = Date(timeIntervalSince1970: Double(ns) / 1_000_000_000)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy/MM/dd HH:mm"
    return fmt.string(from: date)
}

// --fast-scan is only meaningful with InodeSortedScanner (NTFS external).
// It will be passed through; IndexManager ignores it for non-NTFS paths.

// MARK: - Header

let modeLabel: String
switch scanMode {
case .full:         modeLabel = "full (all files)"
case .priorityOnly: modeLabel = fastScan
    ? "priority-only + fast-scan  (no lstat for files; size/mtime=0 pending)"
    : "priority-only  (docs/archives/images/video/audio)"
case .supplement:   modeLabel = "supplement     (fill missing files, preserves existing)"
}

print("QuickSearch M1 — Index Engine")
print("  Scan path  : \(scanPath)")
print("  Database   : \(dbPath)")
print("  Mode       : \(modeLabel)")
if let bs = batchSizeOverride { print("  Batch size : \(bs)") }
if !additionalExcludedDirs.isEmpty {
    print("  Excl. dirs : \(additionalExcludedDirs.joined(separator: ", "))")
}
if case .priorityOnly = scanMode {
    let exts = IndexManager.defaultPriorityExtensions.sorted().joined(separator: " ")
    print("  Extensions : \(exts)")
}
print("")

// MARK: - Main

let startTime = Date()

final class ProgressState: @unchecked Sendable {
    var lastPrintedCount: Int = 0
    var totalIndexed: Int = 0
    var dupWriteRatio: Double = 0
    var finalScanEps: Double = 0
    var finalWriteMs: Double = 0
    var finalScanStats: ScanStats? = nil
}

let exitCode: Int32 = await withCheckedContinuation { continuation in
    Task {
        do {
            let dbURL = URL(fileURLWithPath: dbPath)
            let db = try await DatabaseManager(dbURL: dbURL)
            let manager = IndexManager(db: db)
            let state = ProgressState()

            try await manager.startFullScan(
                rootPath: scanPath,
                excludePrefixes: ["/proc", "/sys", "/dev", "/private/var/vm"],
                additionalExcludedDirs: additionalExcludedDirs,
                mode: scanMode,
                fastScan: fastScan,
                batchSizeOverride: batchSizeOverride,
                onProgress: { [state] progress in
                    let count = progress.filesScanned
                    state.totalIndexed = count

                    let isFinal = progress.currentPath.isEmpty
                    if isFinal {
                        state.dupWriteRatio    = progress.dupWriteRatio
                        state.finalScanEps     = progress.scanEntriesPerSec
                        state.finalWriteMs     = progress.dbWriteMsPerBatch
                        state.finalScanStats   = progress.scanStats
                    } else if count - state.lastPrintedCount >= 100_000 {
                        state.lastPrintedCount = count
                        let elapsed = Date().timeIntervalSince(startTime)
                        if progress.scanEntriesPerSec > 0 {
                            print(String(format: "  [%6.1fs] %8d files  scan=%.0f/s  write=%.1fms/batch",
                                         elapsed, count,
                                         progress.scanEntriesPerSec,
                                         progress.dbWriteMsPerBatch))
                        } else {
                            let rate = elapsed > 0 ? Double(count) / elapsed : 0
                            print(String(format: "  [%6.1fs] %8d files  (%.0f files/s)",
                                         elapsed, count, rate))
                        }
                    }
                }
            )

            let elapsed = Date().timeIntervalSince(startTime)
            print("")
            print("Done!")
            print("  Files indexed  : \(state.totalIndexed)")
            print(String(format: "  Total time     : %.2fs", elapsed))
            print(String(format: "  Avg throughput : %.0f files/s",
                         elapsed > 0 ? Double(state.totalIndexed) / elapsed : 0))
            if state.dupWriteRatio > 0 {
                print(String(format: "  Dup ratio      : %.4f  (1.0=no dups)", state.dupWriteRatio))
            }
            if state.finalWriteMs > 0 {
                print(String(format: "  Avg write/batch: %.1fms", state.finalWriteMs))
            }
            // Fast-scan diagnostic: reveals NTFS d_type quality.
            if let ss = state.finalScanStats {
                let total = ss.lstatSkipped + ss.lstatCalled
                print(String(format: "  lstat skipped  : %d / %d (%.1f%%)  ← NTFS d_type coverage",
                             ss.lstatSkipped, total, ss.fastPathRatio * 100))
                if ss.fastPathRatio < 0.5 && fastScan {
                    print("  ⚠  Low fast-path ratio: NTFS driver may return DT_UNKNOWN for most entries.")
                    print("     Fast-scan benefit is limited; consider running without --fast-scan.")
                }
            }
            print("  Database       : \(dbPath)")

            if case .priorityOnly = scanMode {
                if fastScan {
                    print("")
                    print("  Tip: size and mtime are 0 for fast-scan records.")
                    print("       Run with --supplement to fill in metadata.")
                } else {
                    print("")
                    print("  Tip: run with --supplement to index remaining file types.")
                    print("       Or re-run with --fast-scan for a potentially faster initial pass.")
                }
            }

            continuation.resume(returning: 0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            continuation.resume(returning: 1)
        }
    }
}

exit(exitCode)
