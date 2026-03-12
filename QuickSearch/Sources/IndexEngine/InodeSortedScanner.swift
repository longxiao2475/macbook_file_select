// InodeSortedScanner.swift — Inode-ordered directory traversal for NTFS/HDD.
//
// Stage 2 optimization (Plan §3.2.1 "目录级 inode 排序"):
//
//   On a mechanical HDD, the dominant cost is random seek (≈10 ms each).
//   The default readdir() returns entries in NTFS creation order, which is
//   essentially random relative to physical MFT record layout.
//
//   NTFS stores all file metadata (name, size, timestamps) in the MFT (Master
//   File Table). Each file's MFT record number ≈ its inode number. MFT records
//   are allocated sequentially, so sorting directory entries by inode before
//   calling lstat() means accessing MFT records in ascending-address order —
//   turning N random seeks into a near-sequential sweep.
//
// Fast-scan mode (--fast-scan, Plan §4.2 "两阶段可用性"):
//
//   Root cause of residual 97% wait time (v3 result: user=5s, sys=31s, wall=1318s):
//   the bottleneck is NOT disk seek but fskit NTFS driver IPC overhead — each
//   lstat() call is a cross-process RPC to the fskit daemon. inode sort reduces
//   seek distance but cannot reduce IPC call count.
//
//   Fast-scan eliminates lstat() for regular files (DT_REG) by trusting the
//   d_type field returned by readdir(). NTFS stores file-type flags in directory
//   INDEX_ENTRY structures, so the macOS fskit NTFS driver can surface valid
//   d_type without additional disk I/O.
//
//   Expected lstat reduction: ~1.1M → ~110k (directories only) = -90% IPC calls.
//   Projected scan time: ~200–500s (vs 1318s), well within the ≤700s gate.
//
//   Trade-off: records stored with size=0 and mod_time_ns=0 (sentinel values
//   indicating "metadata pending"). Run with --supplement afterwards to fill in
//   size and mtime for fast-scan records.
//
//   If the NTFS driver returns DT_UNKNOWN for file entries, fast-scan
//   automatically falls back to lstat() for those entries, and the summary
//   reports how many entries used each path.

import Foundation
import Darwin

// MARK: - ScanStats (output of a completed scan for diagnostics)

public struct ScanStats: Sendable {
    /// Entries processed without lstat (fast path via d_type).
    public let lstatSkipped: Int
    /// Entries that required lstat (DT_DIR, DT_UNKNOWN, or fast-scan disabled).
    public let lstatCalled: Int

    public var fastPathRatio: Double {
        let total = lstatSkipped + lstatCalled
        return total > 0 ? Double(lstatSkipped) / Double(total) : 0
    }
}

// MARK: - InodeSortedScanner

public struct InodeSortedScanner {

    // Lightweight entry collected from readdir() — no stat() yet.
    private struct DirEntry {
        let inode: UInt64
        let name: String
        let dType: UInt8      // DT_DIR, DT_REG, DT_LNK, DT_UNKNOWN, …
    }

    public let rootPaths: [String]
    public let mountPath: String
    public let volumeID: Int64
    public let excludePrefixes: [String]
    /// O(1) name-based directory exclusion: subtree is skipped entirely.
    public let excludedDirNames: Set<String>
    /// When non-nil, only files whose extension (lowercased) is in this set are recorded.
    public let priorityExtensions: Set<String>?
    public let batchSize: Int
    /// Fast-scan: skip lstat() for DT_REG entries.
    /// Records size=0 and mod_time_ns=0 (fill later via --supplement).
    /// Automatically falls back to lstat() for DT_UNKNOWN entries.
    public let fastScan: Bool

    public init(
        rootPaths: [String],
        mountPath: String,
        volumeID: Int64,
        excludePrefixes: [String] = [],
        excludedDirNames: Set<String> = [],
        priorityExtensions: Set<String>? = nil,
        batchSize: Int = 100_000,
        fastScan: Bool = false
    ) {
        self.rootPaths        = rootPaths
        self.mountPath        = mountPath.hasSuffix("/") ? mountPath : mountPath + "/"
        self.volumeID         = volumeID
        self.excludePrefixes  = excludePrefixes
        self.excludedDirNames = excludedDirNames
        self.priorityExtensions = priorityExtensions
        self.batchSize        = batchSize
        self.fastScan         = fastScan
    }

    // MARK: - scan
    // Returns (stream, statsTask) where statsTask resolves to ScanStats when the stream finishes.

    public func scan() -> (stream: AsyncStream<ScanBatch>, stats: Task<ScanStats, Never>) {
        let rootPaths        = self.rootPaths
        let mountPath        = self.mountPath
        let volumeID         = self.volumeID
        let excludePrefixes  = self.excludePrefixes
        let excludedDirNames = self.excludedDirNames
        let priorityExts     = self.priorityExtensions
        let batchSize        = self.batchSize
        let fastScan         = self.fastScan
        let mountPrefixLen   = mountPath.utf8.count - 1

        // Channel to pass stats from the scan task to the caller.
        let statsContinuation = AsyncStream<ScanStats>.makeStream()
        let statsStream = statsContinuation.stream

        let stream = AsyncStream<ScanBatch>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            Task.detached(priority: .userInitiated) {
                var lstatSkipped = 0
                var lstatCalled  = 0

                // ── Root device for XDEV boundary ────────────────────────────
                var rootSt = Darwin.stat()
                guard !rootPaths.isEmpty,
                      Darwin.lstat(rootPaths[0], &rootSt) == 0 else {
                    continuation.finish()
                    statsContinuation.continuation.yield(ScanStats(lstatSkipped: 0, lstatCalled: 0))
                    statsContinuation.continuation.finish()
                    return
                }
                let rootDev = rootSt.st_dev
                lstatCalled += 1

                var batch: [FileRecord] = []
                batch.reserveCapacity(batchSize)
                var batchStartNs = DispatchTime.now().uptimeNanoseconds

                func flushBatch() {
                    guard !batch.isEmpty else { return }
                    let nowNs  = DispatchTime.now().uptimeNanoseconds
                    let scanMs = Double(nowNs - batchStartNs) / 1_000_000
                    continuation.yield(ScanBatch(records: batch, scanMs: scanMs))
                    batch = []
                    batch.reserveCapacity(batchSize)
                    batchStartNs = DispatchTime.now().uptimeNanoseconds
                }

                // ── relPath from absolute path ───────────────────────────────
                func relPath(of absPath: String) -> String {
                    let u8 = absPath.utf8
                    guard u8.count > mountPrefixLen,
                          let idx = u8.index(u8.startIndex,
                                             offsetBy: mountPrefixLen,
                                             limitedBy: u8.endIndex) else { return "/" }
                    return String(absPath[idx...])
                }

                // ── Extension from filename ──────────────────────────────────
                func fileExt(of name: String) -> String {
                    guard let dot = name.lastIndex(of: "."),
                          dot != name.startIndex else { return "" }
                    return String(name[name.index(after: dot)...]).lowercased()
                }

                // ── Append a record; flush when batch is full ────────────────
                func addRecord(absPath: String, name: String,
                               size: Int64, modTimeNs: Int64,
                               isDir: Bool, inode: UInt64) {
                    let ext = isDir ? "" : fileExt(of: name)
                    if !isDir, let exts = priorityExts, !exts.contains(ext) { return }
                    batch.append(FileRecord(
                        volumeID: volumeID, relPath: relPath(of: absPath),
                        name: name, fileExt: ext,
                        size: size, modTimeNs: modTimeNs,
                        isDir: isDir, inode: inode
                    ))
                    if batch.count >= batchSize { flushBatch() }
                }

                // ── DFS stack ────────────────────────────────────────────────
                // (path, recordSelf): recordSelf=true → emit a dir record for this path.
                var stack: [(path: String, recordSelf: Bool)] =
                    rootPaths.reversed().map { ($0, true) }

                while !stack.isEmpty {
                    if Task.isCancelled { break }
                    let (dirPath, recordSelf) = stack.removeLast()

                    // Record root dirs themselves.
                    if recordSelf {
                        var st = Darwin.stat()
                        if Darwin.lstat(dirPath, &st) == 0, st.st_dev == rootDev {
                            lstatCalled += 1
                            let n = (dirPath as NSString).lastPathComponent
                            addRecord(absPath: dirPath, name: n,
                                      size: Int64(st.st_size),
                                      modTimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                                              + Int64(st.st_mtimespec.tv_nsec),
                                      isDir: true, inode: UInt64(st.st_ino))
                        }
                    }

                    let dirName = (dirPath as NSString).lastPathComponent
                    if recordSelf && excludedDirNames.contains(dirName) { continue }
                    if !excludePrefixes.isEmpty,
                       excludePrefixes.contains(where: { dirPath.hasPrefix($0) }) { continue }

                    // ── Open directory ───────────────────────────────────────
                    guard let dir = Darwin.opendir(dirPath) else { continue }

                    var entries: [DirEntry] = []
                    while let ent = Darwin.readdir(dir) {
                        let name: String = withUnsafePointer(to: ent.pointee.d_name) { ptr in
                            ptr.withMemoryRebound(to: CChar.self,
                                                  capacity: MemoryLayout.size(ofValue: ent.pointee.d_name)) {
                                String(cString: $0)
                            }
                        }
                        guard name != "." && name != ".." else { continue }
                        if ent.pointee.d_type == DT_DIR && excludedDirNames.contains(name) {
                            continue
                        }
                        entries.append(DirEntry(inode: UInt64(ent.pointee.d_ino),
                                                name: name,
                                                dType: ent.pointee.d_type))
                    }
                    Darwin.closedir(dir)

                    // ── Sort by inode: near-sequential MFT access on HDD ─────
                    entries.sort { $0.inode < $1.inode }

                    // ── Process entries ──────────────────────────────────────
                    var subdirs: [String] = []

                    for entry in entries {
                        if Task.isCancelled { break }
                        let fullPath = dirPath + "/" + entry.name

                        let dtype = entry.dType

                        if fastScan && dtype == UInt8(DT_REG) {
                            // ── Fast path: DT_REG, skip lstat ───────────────
                            // Relies on NTFS driver returning valid d_type from readdir.
                            // Falls through to lstat for DT_UNKNOWN entries.
                            let ext = fileExt(of: entry.name)
                            if let exts = priorityExts, !exts.contains(ext) {
                                lstatSkipped += 1   // counted even when filtered out
                                continue
                            }
                            batch.append(FileRecord(
                                volumeID: volumeID, relPath: relPath(of: fullPath),
                                name: entry.name, fileExt: ext,
                                size: 0, modTimeNs: 0,          // sentinel: metadata pending
                                isDir: false, inode: entry.inode
                            ))
                            if batch.count >= batchSize { flushBatch() }
                            lstatSkipped += 1

                        } else if dtype == UInt8(DT_LNK) {
                            // Skip symlinks (FTS_PHYSICAL equivalent).
                            continue

                        } else {
                            // DT_DIR, DT_UNKNOWN, DT_REG (non-fast), or others → lstat.
                            var st = Darwin.stat()
                            guard Darwin.lstat(fullPath, &st) == 0 else { continue }
                            guard st.st_dev == rootDev else { continue }   // XDEV boundary
                            lstatCalled += 1

                            let mode = st.st_mode & S_IFMT
                            let isDir     = mode == S_IFDIR
                            let isSymlink = mode == S_IFLNK
                            guard !isSymlink else { continue }

                            // Post-lstat dir exclusion (catches DT_UNKNOWN dirs too).
                            if isDir && excludedDirNames.contains(entry.name) { continue }

                            let modTimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                                          + Int64(st.st_mtimespec.tv_nsec)
                            addRecord(absPath: fullPath, name: entry.name,
                                      size: Int64(st.st_size), modTimeNs: modTimeNs,
                                      isDir: isDir, inode: UInt64(st.st_ino))

                            if isDir { subdirs.append(fullPath) }
                        }
                    }

                    // Collect dirs from fast-path (DT_DIR | fastScan) — still lstat for XDEV.
                    // NOTE: In fast-scan mode DT_DIR falls through to the default lstat branch,
                    // so subdirs populated there are already correct. No separate handling needed.

                    // Push subdirs reversed so smallest inode pops first (DFS inode order).
                    for subdir in subdirs.reversed() {
                        stack.append((path: subdir, recordSelf: false))
                    }
                }

                flushBatch()
                continuation.finish()
                statsContinuation.continuation.yield(ScanStats(lstatSkipped: lstatSkipped,
                                                               lstatCalled: lstatCalled))
                statsContinuation.continuation.finish()
            }
        }

        // Wrap the one-shot stats stream into a Task for clean consumption.
        let statsTask = Task<ScanStats, Never> {
            for await s in statsStream { return s }
            return ScanStats(lstatSkipped: 0, lstatCalled: 0)
        }

        return (stream: stream, stats: statsTask)
    }
}
