// IndexManager.swift — Orchestrates the full-rebuild pipeline with performance optimizations.
//
// Full-rebuild pipeline (per optimization plan §3.1–3.7):
//   1. dropSecondaryIndexes()           — eliminate per-row B-tree writes during bulk insert
//   2. enableBulkInsertMode()           — synchronous=OFF, wal_autocheckpoint=0
//   3. deleteFilesForVolume(volumeID)   — clear stale data (skipped in .supplement mode)
//   4. beginBulkWriteSession()          — prepare INSERT stmt once, reuse across all batches
//   5. Parallel subdir scan + root-level shallow scan
//   6. endBulkWriteSession()
//   7. rebuildFTS()
//   8. rebuildSecondaryIndexes() + ANALYZE
//   9. restoreWriteSettings()           — synchronous=NORMAL, wal_checkpoint(TRUNCATE)
//
// Scan modes:
//   .full         — index every file (default behaviour)
//   .priorityOnly — index only priority extensions (docs/archives/images/video/audio);
//                   combines NTFS system dir exclusions + common cache dir exclusions;
//                   target: <700 s on a 4 TB NTFS HDD with 1.6 M files
//   .supplement   — add previously-skipped files; skips deleteFilesForVolume so existing
//                   records are preserved; INSERT OR IGNORE handles deduplication
//
// Parallelism strategy:
//   APFS/HFS+:              min(cpu, 8)  — internal SSDs benefit from parallel fts
//   NTFS/exFAT/FAT/unknown: 1           — single-threaded driver; parallel = contention
//
// Stage 0 instrumentation: ScanProgress includes scan_entries_per_sec, db_write_ms_per_batch,
//   dup_write_ratio — enough to determine whether the bottleneck is scan I/O or DB writes.

import Foundation
import Darwin
import Database

// MARK: - ScanMode

public enum ScanMode: Sendable {
    /// Index every file encountered (default).
    case full
    /// Index only priority extensions; skip common cache/build directories.
    /// Fastest initial scan. Use `supplement` later to fill in the rest.
    case priorityOnly
    /// Add files not yet in the database. Preserves existing records.
    /// Suitable as a long-running background task after a `priorityOnly` run.
    case supplement
}

// MARK: - ScanProgress

public struct ScanProgress: Sendable {
    public let filesScanned: Int
    public let elapsedSeconds: Double
    public let currentPath: String

    // ── Stage 0: observability fields ───────────────────────────────────────
    /// Scanned entries per second in the most recent 100 k window (0 before first milestone).
    public let scanEntriesPerSec: Double
    /// Average time spent inside db.writeBatch() per call, in milliseconds.
    public let dbWriteMsPerBatch: Double
    /// Ratio scan_ops_total / unique_rows written. 1.0 = no duplicates; >1.0 = some skipped.
    /// Non-zero only in the final progress event.
    public let dupWriteRatio: Double
    /// Fast-scan stats: lstat calls skipped / called. Non-nil only in the final progress event
    /// when InodeSortedScanner is used. Use fastPathRatio to gauge NTFS d_type quality.
    public let scanStats: ScanStats?

    public init(filesScanned: Int, elapsedSeconds: Double, currentPath: String,
                scanEntriesPerSec: Double = 0,
                dbWriteMsPerBatch: Double = 0,
                dupWriteRatio: Double = 0,
                scanStats: ScanStats? = nil) {
        self.filesScanned = filesScanned
        self.elapsedSeconds = elapsedSeconds
        self.currentPath = currentPath
        self.scanEntriesPerSec = scanEntriesPerSec
        self.dbWriteMsPerBatch = dbWriteMsPerBatch
        self.dupWriteRatio = dupWriteRatio
        self.scanStats = scanStats
    }
}

// MARK: - IndexManager

public actor IndexManager {

    private let db: DatabaseManager
    private var scanTask: Task<Void, Error>?

    /// Maximum concurrent scanner tasks. Overridden at runtime by fsAdaptiveParallelism().
    public var parallelism: Int = min(ProcessInfo.processInfo.activeProcessorCount, 8)

    public init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - NTFS system directory exclusion (applied to all modes on NTFS)
    //
    // These directories exist on every NTFS volume but hold no user files worth indexing.
    // FTS_SKIP by name before any path allocation → eliminates all lstat() inside them.
    private static let ntfsBuiltinExcludedDirs: Set<String> = [
        "$RECYCLE.BIN",
        "System Volume Information",
        "$MFT", "$MFTMirr", "$LogFile", "$Volume", "$AttrDef",
        "$Bitmap", "$Boot", "$BadClus", "$Secure", "$UpCase", "$Extend",
        "pagefile.sys", "hiberfil.sys", "swapfile.sys",
    ]

    // MARK: - Cache / build directory exclusion (applied in .priorityOnly mode)
    //
    // These directories are known to contain only generated/cache/package files.
    // Skipping them as whole subtrees saves all lstat() calls inside — the primary
    // lever for reducing scan time when targeting <700 s.
    //
    // In priorityOnly mode, the logic is: "if this directory can't possibly contain
    // a priority file (pdf/jpg/mp4/…), skip it entirely". The list is conservative
    // (unambiguous cache/build artifacts unlikely to be user-named content dirs).
    //
    // Test result (2026-03-11): priority-only excluded ~500 k files via these rules
    // (1,597 k full → 1,100 k scanned), contributing the full 31 % speedup observed.
    private static let cacheBuiltinExcludedDirs: Set<String> = [
        // JavaScript / Node
        "node_modules", ".npm", ".yarn", ".pnpm-store",
        // Python
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
        "venv", ".venv",
        // JVM (Gradle/Maven)
        ".gradle", ".m2",
        // Apple Xcode
        "DerivedData",
        // Rust
        ".cargo",
        // Generic caches
        ".cache",
        // Version control metadata — no user documents live here
        ".git", ".svn", ".hg", ".bzr",
        // macOS Trash variants on external volumes
        ".Trash", ".Trashes",
        // macOS spotlight index (appears on external HFS+/NTFS)
        ".Spotlight-V100",
        // macOS Time Machine metadata
        ".MobileBackups",
        // Windows thumbnail database directories
        "Thumbs",
    ]

    // MARK: - Priority extensions (used in .priorityOnly mode)
    //
    // Files whose extension is NOT in this set are skipped at the record level.
    // lstat() is still called (fts_read does it internally), so the real speedup
    // comes from the directory-level exclusions above. The extension filter reduces
    // DB size and write load significantly.
    //
    // Covers: documents, archives, images, video, audio, design, executables,
    //         databases, fonts, e-books, and common productivity formats.
    public static let defaultPriorityExtensions: Set<String> = [
        // Documents
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "odt", "ods", "odp", "txt", "md", "markdown", "rtf",
        "pages", "numbers", "key", "epub", "mobi", "azw", "azw3",
        "wps", "et", "dps",                // WPS Office
        "csv", "tsv",                       // Tabular data
        // Archives
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
        "iso", "dmg", "pkg", "deb", "rpm", "apk", "ipa",
        "cab", "lzh", "ace", "z",
        // Images
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif",
        "heic", "heif", "webp", "svg", "ico",
        "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "dng",
        "psd", "ai", "xcf",
        // Videos
        "mp4", "mkv", "avi", "mov", "wmv", "flv", "m4v",
        "ts", "rmvb", "webm", "m2ts", "vob", "3gp",
        "rm", "asf", "f4v",
        // Audio
        "mp3", "aac", "flac", "wav", "m4a", "ogg", "wma",
        "aiff", "ape", "opus", "mid", "midi",
        // Design & creative
        "sketch", "fig", "xd", "indd",
        // Executables / installers
        "exe", "msi",
        // Torrents
        "torrent",
        // Databases (user data)
        "db", "sqlite", "sqlite3", "mdb", "accdb",
        // Fonts
        "ttf", "otf", "woff", "woff2",
        // E-books / comics
        "djvu", "cbr", "cbz",
        // Subtitles
        "srt", "ass", "ssa",
    ]

    // MARK: - Batch size
    private static let defaultBatchSize = 100_000

    /// Full (or supplement) scan of `rootPath`. Fires `onProgress` every 100 k files and once on completion.
    /// Cancels any running scan before starting.
    ///
    /// - Parameters:
    ///   - mode: `.full` (default), `.priorityOnly`, or `.supplement`.
    ///   - parallelismOverride: Force a specific worker count (nil = FS-adaptive default).
    ///   - batchSizeOverride: Force a specific batch size for A/B testing (nil = 100k).
    public func startFullScan(
        rootPath: String,
        excludePrefixes: [String] = [],
        additionalExcludedDirs: [String] = [],
        mode: ScanMode = .full,
        fastScan: Bool = false,
        parallelismOverride: Int? = nil,
        batchSizeOverride: Int? = nil,
        onProgress: @Sendable @escaping (ScanProgress) -> Void
    ) async throws {

        scanTask?.cancel()
        scanTask = nil

        let volumeInfo = try VolumeInfo.forURL(URL(fileURLWithPath: rootPath))
        let volumeID = try await upsertVolume(volumeInfo)

        let workerCount = parallelismOverride
            ?? fsAdaptiveParallelism(fsType: volumeInfo.fsType, isExternal: volumeInfo.isExternal)

        let isNTFS = volumeInfo.fsType.lowercased().hasPrefix("ntfs")

        // Build the directory exclusion set from mode + filesystem type.
        var excludedDirNames: Set<String> = isNTFS ? IndexManager.ntfsBuiltinExcludedDirs : []
        let priorityExtensions: Set<String>?

        switch mode {
        case .full:
            priorityExtensions = nil
        case .priorityOnly:
            // Add cache dir exclusions on top of NTFS system dirs.
            excludedDirNames.formUnion(IndexManager.cacheBuiltinExcludedDirs)
            priorityExtensions = IndexManager.defaultPriorityExtensions
        case .supplement:
            // Supplement: scan everything, no extra dir exclusions, no extension filter.
            priorityExtensions = nil
        }
        // User-specified additional directory exclusions (--exclude-dir).
        if !additionalExcludedDirs.isEmpty {
            excludedDirNames.formUnion(additionalExcludedDirs)
        }

        let batchSize = batchSizeOverride ?? IndexManager.defaultBatchSize

        // Stage 2 (Plan §3.2.1): use inode-sorted scanner for NTFS external HDD.
        // On mechanical HDD, sorting directory entries by inode (≈ MFT record number)
        // before calling lstat() converts random seeks into a near-sequential sweep,
        // targeting 30–50 % scan time reduction on top of the priority-mode savings.
        //
        // InodeSortedScanner is single-threaded (workerCount forced to 1 for NTFS anyway)
        // and handles the root path directly — no partitioning or shallowScanner needed.
        let useInodeSort = isNTFS && volumeInfo.isExternal

        // ── Setup phase (order matters) ──────────────────────────────────────
        try await db.dropSecondaryIndexes()
        try await db.enableBulkInsertMode()
        // Supplement mode preserves existing records: skip the delete so INSERT OR IGNORE
        // in beginBulkWriteSession handles deduplication via the (volume_id, rel_path) UNIQUE key.
        if mode != .supplement {
            try await db.deleteFilesForVolume(volumeID)
        }
        try await db.beginBulkWriteSession()

        let writer = BatchWriter(db: db)
        let startDate = Date()

        // Partitioning is only needed for parallel BSDScanner (APFS/SSD paths).
        // For NTFS+InodeSortedScanner we scan from the root directly (single thread).
        let (subdirs, hasRootFiles): ([String], Bool)
        if useInodeSort {
            (subdirs, hasRootFiles) = ([], false)
        } else {
            (subdirs, hasRootFiles) = partitionRootContents(rootPath: rootPath,
                                                             excludePrefixes: excludePrefixes)
        }

        let task = Task<Void, Error> {
            do {
                let progress = ProgressAccumulator()

                if useInodeSort {
                    // ── Stage 2 path: inode-sorted single-threaded scanner ────
                    let scanner = InodeSortedScanner(
                        rootPaths: [rootPath],
                        mountPath: volumeInfo.mountPath,
                        volumeID: volumeID,
                        excludePrefixes: excludePrefixes,
                        excludedDirNames: excludedDirNames,
                        priorityExtensions: priorityExtensions,
                        batchSize: batchSize,
                        fastScan: fastScan
                    )
                    let (stream, statsTask) = scanner.scan()
                    for await sb in stream {
                        if Task.isCancelled { break }
                        let written = try await writer.write(batch: sb.records)
                        let avgWriteMs = await writer.avgWriteMsPerBatch
                        if let eps = await progress.add(batchCount: sb.records.count,
                                                        totalWritten: written,
                                                        scanMs: sb.scanMs) {
                            let elapsed = Date().timeIntervalSince(startDate)
                            onProgress(ScanProgress(
                                filesScanned: written,
                                elapsedSeconds: elapsed,
                                currentPath: rootPath,
                                scanEntriesPerSec: eps,
                                dbWriteMsPerBatch: avgWriteMs
                            ))
                        }
                    }
                    // Capture stats for final progress event.
                    let scanStats = await statsTask.value
                    await progress.setScanStats(scanStats)
                } else {
                    // ── Existing path: parallel BSDScanner (APFS/HFS+/others) ─
                    try await withThrowingTaskGroup(of: Void.self) { group in

                        let scanRoots = subdirs.isEmpty ? [rootPath] : subdirs
                        let chunks = makeChunks(roots: scanRoots, count: workerCount)

                        for chunk in chunks {
                            let scanner = BSDScanner(
                                rootPaths: chunk,
                                mountPath: volumeInfo.mountPath,
                                volumeID: volumeID,
                                excludePrefixes: excludePrefixes,
                                excludedDirNames: excludedDirNames,
                                priorityExtensions: priorityExtensions,
                                batchSize: batchSize
                            )
                            let capturedWriter = writer
                            let capturedProgress = progress
                            let capturedStart = startDate
                            let capturedLabel = chunk.first ?? ""

                            group.addTask {
                                for await sb in scanner.scan() {
                                    if Task.isCancelled { return }
                                    let written = try await capturedWriter.write(batch: sb.records)
                                    let avgWriteMs = await capturedWriter.avgWriteMsPerBatch
                                    if let eps = await capturedProgress.add(
                                            batchCount: sb.records.count,
                                            totalWritten: written,
                                            scanMs: sb.scanMs) {
                                        let elapsed = Date().timeIntervalSince(capturedStart)
                                        onProgress(ScanProgress(
                                            filesScanned: written,
                                            elapsedSeconds: elapsed,
                                            currentPath: capturedLabel,
                                            scanEntriesPerSec: eps,
                                            dbWriteMsPerBatch: avgWriteMs
                                        ))
                                    }
                                }
                            }
                        }

                        // Shallow scanner captures files directly in rootPath when subdirs exist.
                        if !subdirs.isEmpty && hasRootFiles {
                            let shallowScanner = BSDScanner(
                                rootPath: rootPath,
                                mountPath: volumeInfo.mountPath,
                                volumeID: volumeID,
                                excludePrefixes: excludePrefixes,
                                excludedDirNames: excludedDirNames,
                                priorityExtensions: priorityExtensions,
                                batchSize: batchSize,
                                shallowOnly: true
                            )
                            let capturedWriter = writer
                            group.addTask {
                                for await sb in shallowScanner.scan() {
                                    if Task.isCancelled { return }
                                    try await capturedWriter.write(batch: sb.records)
                                }
                            }
                        }

                        try await group.waitForAll()
                    }
                }

                if Task.isCancelled {
                    await db.endBulkWriteSession()
                    try? await db.rebuildSecondaryIndexes()
                    try? await db.restoreWriteSettings()
                    return
                }

                // ── Finalize phase ───────────────────────────────────────────
                await db.endBulkWriteSession()
                try await db.rebuildFTS()
                try await db.rebuildSecondaryIndexes()
                try await db.restoreWriteSettings()
                try await updateLastScan(volumeUUID: volumeInfo.uuid)

                let scanOpsTotal = await progress.totalScanOps
                let writerCount = await writer.count
                let finalCount: Int = (try? await db.countFiles()) ?? writerCount
                let avgWriteMs = await writer.avgWriteMsPerBatch
                let dupRatio = finalCount > 0 ? Double(scanOpsTotal) / Double(finalCount) : 1.0
                let finalStats = await progress.scanStats

                let elapsed = Date().timeIntervalSince(startDate)
                onProgress(ScanProgress(
                    filesScanned: finalCount,
                    elapsedSeconds: elapsed,
                    currentPath: "",
                    scanEntriesPerSec: finalCount > 0 ? Double(finalCount) / elapsed : 0,
                    dbWriteMsPerBatch: avgWriteMs,
                    dupWriteRatio: dupRatio,
                    scanStats: finalStats
                ))

            } catch {
                await db.endBulkWriteSession()
                try? await db.rebuildSecondaryIndexes()
                try? await db.restoreWriteSettings()
                throw error
            }
        }

        scanTask = task
        try await task.value
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Private helpers

    private func fsAdaptiveParallelism(fsType: String, isExternal: Bool) -> Int {
        let fs = fsType.lowercased()
        let slowFSPrefixes = ["ntfs", "exfat", "fat", "msdos", "fuse", "smbfs", "nfs"]
        if slowFSPrefixes.contains(where: { fs.hasPrefix($0) || fs.contains($0) }) {
            return 1
        }
        if isExternal { return min(parallelism, 2) }
        return parallelism
    }

    private func partitionRootContents(
        rootPath: String,
        excludePrefixes: [String]
    ) -> (subdirs: [String], hasRootFiles: Bool) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: rootPath) else {
            return ([], false)
        }
        var subdirs: [String] = []
        var hasRootFiles = false
        for item in contents {
            let full = (rootPath as NSString).appendingPathComponent(item)
            guard !excludePrefixes.contains(where: { full.hasPrefix($0) }) else { continue }
            var st = Darwin.stat()
            let isRealDir = Darwin.lstat(full, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            if isRealDir { subdirs.append(full) } else { hasRootFiles = true }
        }
        return (subdirs, hasRootFiles)
    }

    private func makeChunks(roots: [String], count: Int) -> [[String]] {
        guard !roots.isEmpty else { return [] }
        let n = min(max(count, 1), roots.count)
        var chunks: [[String]] = Array(repeating: [], count: n)
        for (i, root) in roots.enumerated() { chunks[i % n].append(root) }
        return chunks.filter { !$0.isEmpty }
    }

    private func upsertVolume(_ info: VolumeInfo) async throws -> Int64 {
        return try await db.upsertVolumeRecord(
            uuid: info.uuid, name: info.name, mountPath: info.mountPath,
            fsType: info.fsType, totalSize: info.totalSize, isExternal: info.isExternal
        )
    }

    private func updateLastScan(volumeUUID: String) async throws {
        let now = Date().timeIntervalSinceReferenceDate
        try await db.updateLastScan(volumeUUID: volumeUUID, timestamp: now)
    }
}

// MARK: - ProgressAccumulator

private actor ProgressAccumulator {
    private var lastMilestone: Int = 0
    private var scanOpsTotal: Int = 0
    private var windowScanOps: Int = 0
    private var windowScanMs: Double = 0
    private var _scanStats: ScanStats? = nil

    func add(batchCount: Int, totalWritten: Int, scanMs: Double) -> Double? {
        scanOpsTotal += batchCount
        windowScanOps += batchCount
        windowScanMs += scanMs

        let milestone = (totalWritten / 100_000) * 100_000
        guard milestone > lastMilestone, milestone > 0 else { return nil }

        let eps = windowScanMs > 0 ? Double(windowScanOps) / (windowScanMs / 1000) : 0
        lastMilestone = milestone
        windowScanOps = 0
        windowScanMs = 0
        return eps
    }

    func setScanStats(_ stats: ScanStats) { _scanStats = stats }

    var totalScanOps: Int { scanOpsTotal }
    var scanStats: ScanStats? { _scanStats }
}

// MARK: - Errors

public enum IndexError: Error, LocalizedError {
    case volumeInfoFailed(String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .volumeInfoFailed(let path, let err):
            return "Cannot resolve volume for '\(path)': \(err.localizedDescription)"
        }
    }
}
