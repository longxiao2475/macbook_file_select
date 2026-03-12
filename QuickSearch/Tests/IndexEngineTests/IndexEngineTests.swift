// IndexEngineTests.swift — Unit tests for M1 components using Swift Testing.

import Testing
import Foundation
@testable import IndexEngine
@testable import Database

// MARK: - DatabaseManager tests

@Suite("DatabaseManager")
struct DatabaseManagerTests {

    static func makeTempDB() async throws -> (DatabaseManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("test.db")
        let db = try await DatabaseManager(dbURL: url)
        return (db, dir)
    }

    @Test("Schema creates all required tables")
    func schemaCreated() async throws {
        let (db, dir) = try await makeTempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        // These execute() calls will throw if the tables don't exist
        try await db.execute(sql: "SELECT COUNT(*) FROM files")
        try await db.execute(sql: "SELECT COUNT(*) FROM volumes")
        try await db.execute(sql: "SELECT COUNT(*) FROM exclude_rules")
    }

    @Test("Prepared statement bind and column read")
    func statementBindAndRead() async throws {
        let (db, dir) = try await makeTempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stmt = try await db.prepare(sql: "SELECT ? + ?")
        try stmt.bind(int: 40, at: 1)
        try stmt.bind(int: 2,  at: 2)
        let hasRow = try stmt.step()
        #expect(hasRow)
        #expect(stmt.columnInt64(0) == 42)
    }

    @Test("Text bind round-trip via INSERT/SELECT")
    func textBindRoundTrip() async throws {
        let (db, dir) = try await makeTempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await db.run(sql: """
            INSERT INTO volumes (volume_uuid, volume_name, mount_path, fs_type)
            VALUES (?, ?, ?, ?)
            """) { stmt in
            try stmt.bind(text: "test-uuid-1", at: 1)
            try stmt.bind(text: "TestVol",     at: 2)
            try stmt.bind(text: "/Volumes/T",  at: 3)
            try stmt.bind(text: "apfs",         at: 4)
        }
        let sel = try await db.prepare(sql: "SELECT volume_name FROM volumes WHERE volume_uuid = ?")
        try sel.bind(text: "test-uuid-1", at: 1)
        let found = try sel.step()
        #expect(found)
        #expect(sel.columnText(0) == "TestVol")
    }
}

// MARK: - VolumeInfo tests

@Suite("VolumeInfo")
struct VolumeInfoTests {

    @Test("forURL returns non-empty UUID and mount path")
    func forURL() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let info = try VolumeInfo.forURL(home)
        #expect(!info.uuid.isEmpty)
        #expect(!info.mountPath.isEmpty)
        #expect(info.totalSize > 0)
    }

    @Test("allMounted returns at least boot volume")
    func allMounted() {
        let volumes = VolumeInfo.allMounted()
        #expect(!volumes.isEmpty)
    }
}

// MARK: - BSDScanner tests

@Suite("BSDScanner")
struct BSDScannerTests {

    static func makeTempDir(fileCount: Int = 0) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            try "test".write(to: dir.appendingPathComponent("file_\(i).txt"),
                             atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("Scans all files in batches ≤ batchSize")
    func batchSizes() async throws {
        let dir = try makeTempDir(fileCount: 25)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scanner = BSDScanner(rootPath: dir.path, volumeUUID: "vol", batchSize: 10)
        var total = 0
        for await batch in scanner.scan() {
            #expect(batch.count <= 10)
            total += batch.count
        }
        #expect(total >= 25)
    }

    @Test("FileRecord fields are populated correctly")
    func fieldExtraction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "let x = 1".write(to: dir.appendingPathComponent("hello.swift"),
                              atomically: true, encoding: .utf8)

        let scanner = BSDScanner(rootPath: dir.path, volumeUUID: "vol", batchSize: 100)
        var records: [FileRecord] = []
        for await batch in scanner.scan() { records.append(contentsOf: batch) }

        let f = records.first(where: { $0.name == "hello.swift" })
        #expect(f != nil)
        #expect(f?.fileExt == "swift")
        #expect(f?.isDir == false)
        #expect((f?.size ?? 0) > 0)
        #expect((f?.modTimeNs ?? 0) > 0)
    }

    @Test("Exclude prefix filters out paths")
    func excludePrefix() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secret = dir.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try "hidden".write(to: secret.appendingPathComponent("private.txt"),
                           atomically: true, encoding: .utf8)
        try "visible".write(to: dir.appendingPathComponent("visible.txt"),
                            atomically: true, encoding: .utf8)

        let scanner = BSDScanner(rootPath: dir.path, volumeUUID: "vol",
                                 excludePrefixes: [secret.path], batchSize: 100)
        var records: [FileRecord] = []
        for await batch in scanner.scan() { records.append(contentsOf: batch) }

        let names = records.map { $0.name }
        #expect(names.contains("visible.txt"))
        #expect(!names.contains("private.txt"))
    }
}

// MARK: - BatchWriter tests

@Suite("BatchWriter")
struct BatchWriterTests {

    @Test("Inserts records and count matches")
    func insertBatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await DatabaseManager(dbURL: dir.appendingPathComponent("test.db"))
        let writer = BatchWriter(db: db)

        let records: [FileRecord] = (0..<50).map { i in
            FileRecord(volumeUUID: "vol-1",
                       fullPath: "/tmp/f\(i).txt",
                       parentPath: "/tmp",
                       name: "f\(i).txt",
                       fileExt: "txt",
                       size: Int64(i * 100),
                       modTimeNs: 1_700_000_000_000_000_000,
                       isDir: false,
                       inode: UInt64(1000 + i))
        }

        let written = try await writer.write(batch: records)
        #expect(written == 50)

        let stmt = try await db.prepare(sql: "SELECT COUNT(*) FROM files WHERE volume_uuid = 'vol-1'")
        _ = try stmt.step()
        #expect(stmt.columnInt64(0) == 50)
    }
}

// MARK: - IndexManager integration test

@Suite("IndexManager")
struct IndexManagerTests {

    @Test("Full scan indexes files and fires progress")
    func fullScan() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<10 {
            try "content".write(to: dir.appendingPathComponent("doc_\(i).txt"),
                                atomically: true, encoding: .utf8)
        }

        let dbURL = dir.appendingPathComponent("idx.db")
        let db = try await DatabaseManager(dbURL: dbURL)
        let manager = IndexManager(db: db)

        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()

        try await manager.startFullScan(rootPath: dir.path) { [counter] _ in
            counter.value += 1
        }

        #expect(counter.value > 0)
        let stmt = try await db.prepare(sql: "SELECT COUNT(*) FROM files")
        _ = try stmt.step()
        #expect(stmt.columnInt64(0) >= 10)
    }
}
