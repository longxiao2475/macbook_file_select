// Schema.swift — DDL per PRD §6.2 (optimised v2)
//
// Key changes vs v1:
//   - volumes.id INTEGER PK (replaces TEXT UUID in every files row → saves ~52 MB per 1M files)
//   - files stores rel_path (relative to mount_path, not full_path → saves mount prefix overhead)
//   - parent_path column REMOVED (derived in queries → saves ~238 MB index + ~140 MB table data)
//   - page_size = 8192 (set once before table creation; doubles page cache efficiency)
//   - Dropped low-value indexes mod_ns/is_dir during M1; add back in M3 when query patterns known

enum Schema {

    // PRAGMA: set page_size BEFORE any tables are created; ignored on existing DB
    static let pageSizeSQL = "PRAGMA page_size = 8192"

    static let pragmas: [String] = [
        "PRAGMA journal_mode = WAL",
        "PRAGMA synchronous = NORMAL",
        "PRAGMA temp_store = MEMORY",
        "PRAGMA cache_size = -131072",   // 128 MB page cache
        "PRAGMA mmap_size = 536870912",  // 512 MB mmap for read path
    ]

    // volumes — integer PK avoids storing 36-char UUID in every files row
    static let createVolumesTable = """
        CREATE TABLE IF NOT EXISTS volumes (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            volume_uuid   TEXT    NOT NULL UNIQUE,
            volume_name   TEXT    NOT NULL,
            mount_path    TEXT    NOT NULL,
            fs_type       TEXT    NOT NULL,
            total_size    INTEGER DEFAULT 0,
            is_external   INTEGER DEFAULT 0,
            index_policy  TEXT    DEFAULT 'auto',
            last_scan_at  REAL    DEFAULT 0
        )
        """

    // files — rel_path is relative to volumes.mount_path (strips the common volume prefix)
    static let createFilesTable = """
        CREATE TABLE IF NOT EXISTS files (
            id            INTEGER PRIMARY KEY,
            volume_id     INTEGER NOT NULL REFERENCES volumes(id),
            rel_path      TEXT    NOT NULL,
            name          TEXT    NOT NULL,
            file_ext      TEXT    DEFAULT '',
            size          INTEGER DEFAULT 0,
            mod_time_ns   INTEGER NOT NULL,
            is_dir        INTEGER DEFAULT 0,
            inode         INTEGER DEFAULT 0,
            updated_at    REAL    NOT NULL,
            UNIQUE(volume_id, rel_path)
        )
        """

    // Indexes — only the high-value ones for M1 search patterns
    static let createFilesIndexes: [String] = [
        "CREATE INDEX IF NOT EXISTS idx_files_name    ON files(name)",
        "CREATE INDEX IF NOT EXISTS idx_files_ext     ON files(file_ext)",
        "CREATE INDEX IF NOT EXISTS idx_files_size    ON files(size)",
    ]

    // FTS5 — indexes `name` only (full_path not needed; join via rowid for path display)
    static let createFTSTable = """
        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
            name,
            content='files',
            content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        )
        """

    static let createExcludeRulesTable = """
        CREATE TABLE IF NOT EXISTS exclude_rules (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            rule_type     TEXT NOT NULL,
            pattern       TEXT NOT NULL,
            is_enabled    INTEGER DEFAULT 1
        )
        """

    static let rebuildFTS = "INSERT INTO files_fts(files_fts) VALUES('rebuild')"

    static var allStatements: [String] {
        [createVolumesTable,
         createFilesTable]
        + createFilesIndexes
        + [createFTSTable,
           createExcludeRulesTable]
    }
}
