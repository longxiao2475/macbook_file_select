// BSDScanner.swift — File system traversal using BSD fts_open / fts_read.
// Uses FTS_XDEV to stay within one volume, FTS_PHYSICAL to avoid symlink loops.
//
// FileRecord stores rel_path (path relative to mountPath) rather than the full
// absolute path. This eliminates the repeated mount prefix from every row and
// every index entry, saving significant space for volumes like /Volumes/LX.
//
// Stage 0: per-batch scan timing exposed via the ScanBatch wrapper.
// Stage 1 string optimisations:
//   - File name read via fts_path pointer arithmetic (no NSString.lastPathComponent bridge)
//   - File extension extracted via pure Swift (no NSString.pathExtension bridge)
//   - rel_path built via C-pointer arithmetic (O(1) prefix skip, avoids String.dropFirst)
//   - Name-based directory exclusion (Set<String> O(1) lookup before full path allocation)
// Stage 1 filtering:
//   - excludedDirNames: FTS_SKIP entire directories by name (saves all lstat inside them)
//   - priorityExtensions: when non-nil, only record files with matching extensions

import Foundation
import Darwin

// MARK: - FileRecord

public struct FileRecord: Sendable {
    public let volumeID: Int64     // FK to volumes.id
    public let relPath: String     // path relative to volume's mount_path
    public let name: String
    public let fileExt: String
    public let size: Int64
    public let modTimeNs: Int64    // nanoseconds since epoch
    public let isDir: Bool
    public let inode: UInt64
}

// MARK: - ScanBatch
// Wraps a FileRecord batch with the elapsed scan time to fill it.

public struct ScanBatch: Sendable {
    public let records: [FileRecord]
    /// Wall-clock milliseconds spent inside fts_read loop filling this batch.
    public let scanMs: Double
}

// MARK: - BSDScanner

public struct BSDScanner {

    public let rootPaths: [String]
    public let mountPath: String
    public let volumeID: Int64
    public let excludePrefixes: [String]
    /// O(1) directory name exclusion: FTS_SKIP the entire subtree if basename matches.
    /// Used for NTFS system dirs AND common cache/build dirs (node_modules etc.).
    public let excludedDirNames: Set<String>
    /// When non-nil, only file records whose extension (lowercased) is in this set are
    /// written to the DB. Directories are always recorded. lstat() is still called for
    /// every entry; savings come from fewer DB inserts and less memory pressure.
    /// Combine with excludedDirNames to skip whole cache trees for real lstat savings.
    public let priorityExtensions: Set<String>?
    public let batchSize: Int
    /// When true, scans only the immediate children of rootPaths[0] that are files.
    public let shallowOnly: Bool

    public init(
        rootPaths: [String],
        mountPath: String,
        volumeID: Int64,
        excludePrefixes: [String] = [],
        excludedDirNames: Set<String> = [],
        priorityExtensions: Set<String>? = nil,
        batchSize: Int = 100_000,
        shallowOnly: Bool = false
    ) {
        self.rootPaths = rootPaths
        self.mountPath = mountPath.hasSuffix("/") ? mountPath : mountPath + "/"
        self.volumeID = volumeID
        self.excludePrefixes = excludePrefixes
        self.excludedDirNames = excludedDirNames
        self.priorityExtensions = priorityExtensions
        self.batchSize = batchSize
        self.shallowOnly = shallowOnly
    }

    public init(rootPath: String, mountPath: String, volumeID: Int64,
                excludePrefixes: [String] = [], excludedDirNames: Set<String> = [],
                priorityExtensions: Set<String>? = nil,
                batchSize: Int = 100_000, shallowOnly: Bool = false) {
        self.init(rootPaths: [rootPath], mountPath: mountPath, volumeID: volumeID,
                  excludePrefixes: excludePrefixes, excludedDirNames: excludedDirNames,
                  priorityExtensions: priorityExtensions,
                  batchSize: batchSize, shallowOnly: shallowOnly)
    }

    /// Returns an AsyncStream that yields ScanBatch values (records + scan timing).
    public func scan() -> AsyncStream<ScanBatch> {
        let rootPaths        = self.rootPaths
        let mountPath        = self.mountPath
        let volumeID         = self.volumeID
        let excludePrefixes  = self.excludePrefixes
        let excludedDirNames = self.excludedDirNames
        let priorityExts     = self.priorityExtensions
        let batchSize        = self.batchSize
        let shallowOnly      = self.shallowOnly

        // mountPath ends with "/". We want rel_path to start with "/", so skip
        // (utf8.count - 1) bytes: e.g. "/Volumes/LX/" → skip 11 bytes → "/foo/bar".
        let mountPrefixLen: Int = mountPath.utf8.count - 1

        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            Task.detached(priority: .userInitiated) {
                let cPaths = rootPaths.map { strdup($0) }
                defer { cPaths.forEach { free($0) } }
                var pathArray: [UnsafeMutablePointer<CChar>?] = cPaths + [nil]

                let flags: Int32 = FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV

                guard let fts = pathArray.withUnsafeMutableBufferPointer({ buf in
                    fts_open(buf.baseAddress, flags, nil)
                }) else {
                    continuation.finish()
                    return
                }
                defer { fts_close(fts) }

                var batch: [FileRecord] = []
                batch.reserveCapacity(batchSize)
                var batchStartNs = DispatchTime.now().uptimeNanoseconds

                while let ent = fts_read(fts) {
                    if Task.isCancelled { break }

                    let info = ent.pointee.fts_info
                    guard info != FTS_ERR && info != FTS_NS && info != FTS_DP else { continue }

                    let isDir = info == FTS_D

                    // ── Fast name extraction via fts_path pointer arithmetic ──
                    // fts_name is a char[1] flexible-array member; unsafe to dereference as
                    // a Swift String. Use (fts_pathlen - fts_namelen) offset into fts_path.
                    guard let pathPtr = ent.pointee.fts_path else { continue }
                    let nameOffset = Int(ent.pointee.fts_pathlen) - Int(ent.pointee.fts_namelen)
                    let name = String(cString: pathPtr.advanced(by: nameOffset))
                    guard !name.isEmpty && name != "." && name != ".." else { continue }

                    // ── Directory exclusion by name (O(1) Set, saves all lstat inside) ──
                    if isDir && excludedDirNames.contains(name) {
                        fts_set(fts, ent, FTS_SKIP)
                        continue
                    }

                    // ── Path-prefix exclusion (user-defined full-path rules) ──
                    if !excludePrefixes.isEmpty {
                        let fullPath = String(cString: pathPtr)
                        if excludePrefixes.contains(where: { fullPath.hasPrefix($0) }) {
                            if isDir { fts_set(fts, ent, FTS_SKIP) }
                            continue
                        }
                    }

                    // ── Shallow mode ──
                    let ftsLevel = Int(ent.pointee.fts_level)
                    if shallowOnly {
                        if ftsLevel == 0 { continue }
                        if isDir { fts_set(fts, ent, FTS_SKIP); continue }
                        if ftsLevel > 1 { continue }
                    }

                    // ── Pure-Swift file extension (no NSString bridge) ──
                    let fileExt: String
                    if !isDir, let lastDot = name.lastIndex(of: "."),
                       lastDot != name.startIndex {
                        fileExt = String(name[name.index(after: lastDot)...]).lowercased()
                    } else {
                        fileExt = ""
                    }

                    // ── Priority extension filter ──
                    // Directories are always recorded (needed for path reconstruction).
                    // Files are skipped when a priority set is active and their extension
                    // is not in it. lstat() is already done (by fts_read) so no seek saved,
                    // but DB inserts and memory pressure are reduced significantly.
                    if !isDir, let exts = priorityExts, !exts.contains(fileExt) {
                        continue
                    }

                    // ── Metadata from fts_statp (no extra lstat call) ──
                    let stat = ent.pointee.fts_statp.pointee
                    let size = Int64(stat.st_size)
                    let inode = UInt64(stat.st_ino)
                    let modTimeNs = Int64(stat.st_mtimespec.tv_sec) * 1_000_000_000
                                  + Int64(stat.st_mtimespec.tv_nsec)

                    // ── rel_path via C-pointer arithmetic (O(1) prefix skip) ──
                    let relPath = String(cString: pathPtr.advanced(by: mountPrefixLen))

                    batch.append(FileRecord(
                        volumeID: volumeID,
                        relPath: relPath,
                        name: name,
                        fileExt: fileExt,
                        size: size,
                        modTimeNs: modTimeNs,
                        isDir: isDir,
                        inode: inode
                    ))

                    if batch.count >= batchSize {
                        let nowNs = DispatchTime.now().uptimeNanoseconds
                        let scanMs = Double(nowNs - batchStartNs) / 1_000_000
                        continuation.yield(ScanBatch(records: batch, scanMs: scanMs))
                        batch = []
                        batch.reserveCapacity(batchSize)
                        batchStartNs = DispatchTime.now().uptimeNanoseconds
                    }
                }

                if !batch.isEmpty {
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    let scanMs = Double(nowNs - batchStartNs) / 1_000_000
                    continuation.yield(ScanBatch(records: batch, scanMs: scanMs))
                }
                continuation.finish()
            }
        }
    }
}
