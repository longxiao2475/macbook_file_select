# QuickSearch for Mac — 产品需求与技术实现蓝图

**文档版本**：V1.0
**编制日期**：2026-03-08
**文档状态**：待审核
**目标读者**：
- **Gemini**：需求合规性审核、产品逻辑把控
- **ClaudeCode**：核心逻辑与代码实现
- **CodeX**：代码安全、性能审查与规范合规

---

## 修订记录

| 版本 | 日期 | 修订内容 | 修订人 |
|------|------|----------|--------|
| V1.0 | 2026-03-08 | 初稿，综合多方需求文档编制 | 需求方 |

---

## 零、核心痛点与解法（The "Why"）

> 设计理念：天下武功，唯快不破。克制做加法，专注把"搜文件名"做到极致。

| 原生痛点 | 用户场景描述 | QuickSearch 解法 |
|----------|-------------|-----------------|
| **搜索结果极度不准** | 搜文件名，却出来一堆内容包含该词的文件、邮件、备忘录，满屏无效结果 | **纯文件名匹配引擎**。默认断绝一切内容/元数据索引，仅基于文件树构建 FTS5 倒排索引 |
| **列表不显示路径** | 搜出十个同名文件，无法在同一层级直观看到它们分别在哪个文件夹 | **数据密集型表格 UI**。1:1 复刻 Windows Everything，将"路径"作为独立默认列展示 |
| **大硬盘索引瘫痪** | 2TB 内置/外接移动硬盘，访达/Spotlight 疯狂转圈，占用资源且长时间无法完成索引 | **绕过 Spotlight 自建 SQLite 索引库**。采用 C 语言级 `fts`/`dirent` 底层遍历，结合 SQLite WAL 模式，2TB SSD 初始索引 ≤ 5 分钟 |
| **外接硬盘不被索引** | 插入移动硬盘，访达无法建立有效索引，外接存储文件无法搜索 | **全介质自动识别**。基于 DiskArbitration 框架，挂载即识别，自动触发增量索引 |

---

## 一、项目概述

### 1.1 项目目标

开发一款面向 macOS 平台的**原生极速文件搜索工具**，对标 Windows 平台 Everything（v1.4.1），解决 Mac 原生访达搜索的核心痛点，实现：

1. 毫秒级文件名精准搜索，结果即搜即显，无冗余内容干扰
2. 支持 Mac 内置硬盘与所有挂载的外接存储介质（移动硬盘、U 盘、移动 SSD、SD 卡）
3. 结果列表默认展示**文件路径**，用于区分同名文件
4. 操作逻辑 1:1 对标 Everything，降低 Windows 转 Mac 用户的学习成本

### 1.2 目标用户

- 从 Windows 迁移到 Mac 的用户，有使用 Everything 的经验
- 使用大容量（1TB+）内置或外接存储的 Mac 用户
- 重度文件管理用户（设计师、开发者、内容创作者等）

### 1.3 开发环境

- **开发语言**：Swift 5.10+，核心性能模块混编 C/POSIX API
- **最低兼容系统**：macOS 12.0 Monterey（支持后续所有正式版）
- **芯片支持**：原生适配 Apple Silicon M 系列 + Intel，提供 Universal Binary
- **UI 框架**：AppKit（**绝对禁止在主数据列表使用 SwiftUI**，以保障百万级数据 60fps 滚动）

---

## 二、功能需求（按优先级分级）

> P0：MVP 必须实现；P1：高优先级，第二阶段实现；P2：低优先级，后续迭代

### 2.1 核心搜索功能（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **实时极速搜索** | 用户输入关键词，实时触发搜索，无需回车确认，即搜即显 | 1. 防抖延迟 ≤ 50ms，结果实时刷新；2. 默认仅匹配文件名/文件夹名，不匹配文件内容；3. 大小写不敏感；4. 支持空格分隔的多关键词「与」逻辑 |
| **匹配模式** | 支持多种匹配模式 | 1. 精确匹配、前缀/后缀匹配、模糊匹配；2. 通配符：`*`（任意字符）、`?`（单个字符）；3. P1 阶段支持正则表达式 |
| **搜索对象切换** | 切换搜索对象：全部 / 仅文件 / 仅文件夹 | 切换后实时过滤，无需重新触发搜索 |
| **搜索范围限定** | 指定搜索根目录，仅在指定范围内执行搜索 | 1. 支持手动输入路径、拖拽文件夹指定范围；2. P1 阶段支持保存常用范围为预设 |

### 2.2 高级过滤功能（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **文件类型过滤** | 按文件后缀名或预设类型过滤 | 1. 预设类型：视频、音频、图片、文档、压缩包、代码文件；2. 支持自定义后缀，多后缀组合（如 `.zip,.rar,.7z`） |
| **文件大小过滤** | 按文件大小范围过滤 | 1. 预设区间：空文件、< 1MB、1MB-100MB、100MB-1GB、> 1GB；2. 支持自定义区间，可选 B/KB/MB/GB/TB 单位 |
| **修改时间过滤** | 按文件修改时间过滤 | 1. 预设：今天、昨天、近 7 天、近 30 天、今年；2. 支持自定义时间区间，精确到分钟 |
| **高级搜索语法** | 在搜索框直接输入语法实现过滤，对标 Everything | 详见附录三语法规范，P0 阶段支持 `ext:`、`size:`、`dm:`、`path:`、`folder:`、`file:` |
| **组合过滤** | 所有过滤条件可组合使用 | 修改任意过滤条件后实时生效，结果同步更新 |

### 2.3 索引管理功能（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **全量索引构建** | 首次启动自动扫描，构建全量文件元数据索引 | 1. 索引字段：文件名、完整路径、父目录路径、文件大小、修改时间、创建时间、文件后缀、是否为文件夹；2. 2T SSD ≤ 5 分钟；3. 支持暂停/继续/取消，实时显示进度和已扫描文件数 |
| **增量索引更新** | 监控文件系统变更，实时更新索引 | 1. 基于 FSEvents 框架；2. 文件变更后 ≤ 1s 完成索引同步；3. 系统唤醒、外接存储重新挂载后自动执行增量校验 |
| **外接存储特殊处理** | exFAT/NTFS 等格式的外接硬盘 FSEvents 覆盖不完整 | 针对外接存储实现「目录树快照 Hash 对比」算法，挂载时触发全量比对，找出变更后同步索引 |
| **索引持久化** | 索引数据本地持久化，支持手动重建和清理 | 1. 按存储介质分别管理索引；2. 外接存储卸载后保留索引，重新挂载后自动激活；3. 支持手动触发全量重建 |
| **排除规则** | 支持排除指定目录，减少无效索引 | 1. 默认排除：系统目录（`/System`、`/private`）、隐藏目录；2. 支持用户自定义排除路径 |

### 2.4 存储介质管理（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **自动识别介质** | 自动识别内置硬盘和所有挂载的外接存储 | 基于 DiskArbitration 框架，实时监控挂载/卸载事件，显示介质名称、容量、文件系统类型 |
| **外接存储策略** | 外接存储挂载后提示用户选择处理方式 | 弹窗提示：「本次索引」/「永久自动索引」/「忽略该介质」 |
| **多介质并行搜索** | 同时搜索多个存储介质 | 主界面支持切换：全部介质 / 仅内置硬盘 / 指定外接介质；多介质并行查询，结果合并展示 |

### 2.5 结果展示与操作（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **结果列表展示** | 以表格形式展示，对标 Everything 界面 | 1. 默认 4 列（顺序固定）：**名称、路径、大小、修改时间**；2. 支持列宽调整、列顺序拖拽、列头点击排序；3. 关键词匹配部分高亮显示；4. 支持百万级结果虚拟滚动，60fps 无卡顿 |
| **文件操作** | 鼠标/键盘快速操作 | 1. 双击：系统默认程序打开；2. `Cmd+Enter`：在 Finder 中显示；3. `Space`：QuickLook 预览；4. `Delete`：移到废纸篓 |
| **右键菜单** | 右键提供完整操作项 | 打开、在访达中显示、复制完整路径、复制文件、重命名、移到废纸篓（多选批量支持） |
| **QuickLook 预览** | 空格键触发原生快速预览 | 基于 macOS 原生 QuickLook 框架，与 Finder 行为完全一致 |

### 2.6 系统权限与适配（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **全磁盘访问权限引导** | 首次启动检测并引导开启 FDA | 1. 检测未授权时弹出图文引导窗口；2. 提供按钮一键跳转系统设置；3. 用户授权后自动触发初始索引，无需重启 |
| **后台常驻** | 支持后台运行以保证索引实时性 | 1. 主窗口关闭后可选：后台常驻（菜单栏图标）或完全退出；2. 菜单栏图标支持：快速打开、暂停索引、查看状态、退出 |
| **开机自启** | 用户可设置登录后自动后台启动 | 使用 `SMAppService`（macOS 13+）或 `LaunchAgent`（macOS 12 兼容）实现 |

### 2.7 辅助功能（P1/P2）

1. **个性化设置（P1）**：快捷键自定义（预设 Everything 兼容方案）、UI 主题、行高、结果数上限
2. **搜索历史与书签（P1）**：自动记录搜索历史，支持保存常用搜索为书签，一键复用
3. **日志与故障排查（P1）**：分级记录运行/索引/错误日志，支持故障自检
4. **自动更新（P2）**：检测并一键升级，可关闭完全离线运行

---

## 三、非功能需求

### 3.1 性能指标（强制达标）

| 指标 | 目标值 | 说明 |
|------|--------|------|
| 单关键词搜索响应 | ≤ 100ms | 百万级文件索引下 |
| 多条件组合搜索响应 | ≤ 200ms | 百万级文件索引下 |
| 2T SSD 全量索引构建 | ≤ 5 分钟 | |
| 2T HDD 全量索引构建 | ≤ 15 分钟 | |
| 单文件变更索引更新延迟 | ≤ 1s | |
| 后台空闲内存占用 | ≤ 100MB | |
| 后台空闲 CPU 占用 | ≤ 1% | |
| 索引构建峰值 CPU | ≤ 30% | |
| 索引构建峰值内存 | ≤ 300MB | |
| 主界面运行内存 | ≤ 150MB | |

### 3.2 稳定性需求

1. 崩溃率 ≤ 0.1%，无内存泄漏，连续运行 7×24 小时无异常
2. 程序异常退出或系统强制关机后，索引数据不损坏，可自动恢复
3. 异常场景（无权限目录、损坏介质、中途卸载外接硬盘、磁盘满）下程序不崩溃，给出友好提示

### 3.3 安全性需求

1. 索引数据完全本地存储，**不上传任何云端**
2. **App Sandbox 必须关闭**（`com.apple.security.app-sandbox = NO`），沙盒应用无法实现全盘扫描
3. 所有用户输入的搜索关键词必须使用**参数化查询**，严禁 SQL 字符串拼接

---

## 四、详细技术实现路径

> 本章节为 ClaudeCode 核心实现指引，CodeX 审查重点章节。

### 4.1 整体架构

采用**单进程分层架构**（MVP 阶段），后续可拆分为主进程 + XPC 后台进程。

```
┌─────────────────────────────────────────────┐
│                   UI 层 (AppKit)             │
│   NSWindow / NSTableView / NSSearchField     │
└─────────────────────┬───────────────────────┘
                      │ ViewModel (Observable)
┌─────────────────────▼───────────────────────┐
│              业务逻辑层                       │
│   SearchEngine / FilterParser / BookmarkMgr  │
└──────┬──────────────┬──────────────┬─────────┘
       │              │              │
┌──────▼──────┐ ┌─────▼──────┐ ┌───▼──────────┐
│  索引引擎层  │ │ 文件监控层 │ │ 介质管理层   │
│  SQLite+FTS5│ │ FSEvents   │ │DiskArbitration│
└──────┬──────┘ └─────┬──────┘ └───┬──────────┘
       │              │              │
┌──────▼──────────────▼──────────────▼─────────┐
│              系统适配层                        │
│   BSD fts/stat / C POSIX API / TCC权限检测    │
└───────────────────────────────────────────────┘
```

### 4.2 索引引擎（The Indexer）

#### 4.2.1 数据库设计

```sql
-- 开启性能优化 PRAGMA（程序启动时执行）
PRAGMA journal_mode = WAL;       -- 写前日志，大幅提升并发写入性能
PRAGMA synchronous = NORMAL;     -- 平衡性能与安全
PRAGMA cache_size = -64000;      -- 64MB 查询缓存
PRAGMA temp_store = MEMORY;      -- 临时表存内存

-- 核心元数据表
CREATE TABLE IF NOT EXISTS files (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    volume_id    TEXT    NOT NULL,         -- 所在存储介质唯一 ID（/dev/disk2s1）
    name         TEXT    NOT NULL,         -- 文件名（不含路径）
    parent_path  TEXT    NOT NULL,         -- 父目录完整路径（不含文件名）
    size         INTEGER DEFAULT 0,        -- 文件字节大小，文件夹为 0
    mod_time     REAL    NOT NULL,         -- 修改时间（Unix timestamp）
    create_time  REAL    DEFAULT 0,        -- 创建时间
    file_ext     TEXT    DEFAULT '',       -- 后缀名（小写，不含点号）
    is_dir       INTEGER DEFAULT 0        -- 1=文件夹，0=文件
);

-- 常用查询索引
CREATE INDEX IF NOT EXISTS idx_files_name       ON files(name);
CREATE INDEX IF NOT EXISTS idx_files_parent     ON files(parent_path);
CREATE INDEX IF NOT EXISTS idx_files_volume     ON files(volume_id);
CREATE INDEX IF NOT EXISTS idx_files_ext        ON files(file_ext);
CREATE INDEX IF NOT EXISTS idx_files_size       ON files(size);
CREATE INDEX IF NOT EXISTS idx_files_mod_time   ON files(mod_time);

-- FTS5 虚拟表（仅索引 name，保证搜索精准且索引体积小）
CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
    name,
    content='files',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
    -- 注：unicode61 支持 Unicode 规范化，兼容中文字符匹配
    -- 拼音搜索需额外集成 libpinyin 或 jieba 分词器（P1 阶段）
);

-- FTS 触发器（保证主表与 FTS 表同步）
CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
    INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
END;
CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
END;
CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
    INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
END;

-- 存储介质管理表
CREATE TABLE IF NOT EXISTS volumes (
    volume_id    TEXT PRIMARY KEY,         -- BSD 设备路径，如 /dev/disk2s1
    volume_name  TEXT NOT NULL,            -- 用户可见名称，如 "My Passport"
    mount_path   TEXT NOT NULL,            -- 挂载路径，如 /Volumes/My Passport
    fs_type      TEXT NOT NULL,            -- 文件系统类型：APFS/HFS+/exFAT/NTFS/FAT32
    total_size   INTEGER DEFAULT 0,
    is_external  INTEGER DEFAULT 0,        -- 1=外接介质
    is_indexed   INTEGER DEFAULT 0,        -- 1=已完成索引
    last_scan    REAL    DEFAULT 0,        -- 上次全量扫描时间戳
    index_policy TEXT    DEFAULT 'auto'    -- auto/once/ignore
);

-- 用户自定义排除规则表
CREATE TABLE IF NOT EXISTS exclude_rules (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_type    TEXT NOT NULL,            -- path/ext/name
    pattern      TEXT NOT NULL,            -- 规则内容
    is_enabled   INTEGER DEFAULT 1
);
```

#### 4.2.2 初始极速扫描实现

```swift
// 核心原则：禁止使用 FileManager.enumerator（高层 API 太慢）
// 必须使用 POSIX BSD fts 系列函数，性能比 FileManager 高 10x+

import Darwin  // 引入 fts.h / stat.h

class FileSystemScanner {

    // 批量写入缓冲区大小（达到此值立即 flush，控制内存水位）
    private let kBatchSize = 10_000

    func scanVolume(_ mountPath: String, volumeId: String) {
        let pathBytes = (mountPath as NSString).utf8String
        var pathsArray: [UnsafeMutablePointer<CChar>?] = [
            strdup(pathBytes!), nil
        ]
        defer { pathsArray.forEach { free($0) } }

        // FTS_NOCHDIR: 不改变工作目录
        // FTS_PHYSICAL: 不跟随符号链接（防止循环）
        // FTS_XDEV:     不跨越文件系统边界（防止越界扫描）
        guard let fts = fts_open(&pathsArray, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, nil) else {
            return
        }
        defer { fts_close(fts) }

        var batch: [FileRecord] = []
        batch.reserveCapacity(kBatchSize)

        while let entry = fts_read(fts) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_F, FTS_D:  // 普通文件 或 目录
                let name = String(cString: entry.pointee.fts_name)
                let path = String(cString: entry.pointee.fts_path)

                // 跳过隐藏文件（以 . 开头）——可由用户配置
                guard !name.hasPrefix(".") else { continue }

                // 跳过用户自定义排除规则
                guard !isExcluded(path: path) else {
                    // 若是目录则跳过整个子树
                    if Int32(entry.pointee.fts_info) == FTS_D {
                        fts_set(fts, entry, FTS_SKIP)
                    }
                    continue
                }

                let stat = entry.pointee.fts_statp!.pointee
                let record = FileRecord(
                    volumeId:   volumeId,
                    name:       name,
                    parentPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                    size:       Int64(stat.st_size),
                    modTime:    Double(stat.st_mtimespec.tv_sec),
                    createTime: Double(stat.st_birthtimespec.tv_sec),
                    fileExt:    URL(fileURLWithPath: name).pathExtension.lowercased(),
                    isDir:      Int32(entry.pointee.fts_info) == FTS_D ? 1 : 0
                )
                batch.append(record)

                // 达到批量上限，立即写入 DB 并清空缓冲区（控制内存水位 ≤ 300MB）
                if batch.count >= kBatchSize {
                    flushBatch(&batch)
                }

            case FTS_ERR, FTS_DNR:  // 无权限目录，静默跳过，记录日志
                LogManager.shared.warn("No permission: \(String(cString: entry.pointee.fts_path))")

            default:
                break
            }
        }

        // 写入剩余数据
        if !batch.isEmpty {
            flushBatch(&batch)
        }
    }

    private func flushBatch(_ batch: inout [FileRecord]) {
        // 使用事务批量写入，速度提升 50x+
        DatabaseManager.shared.insertBatch(batch)
        batch.removeAll(keepingCapacity: true)
    }
}
```

#### 4.2.3 多线程扫描策略

```swift
// 针对不同宗卷开启独立扫描线程，设置低 QoS 避免影响系统
let scanQueue = DispatchQueue(
    label: "com.quicksearch.scanner",
    qos: .utility,           // 低优先级，避免风扇狂转
    attributes: .concurrent
)

// 每个 Volume 独立并发扫描
for volume in volumesToScan {
    scanQueue.async {
        self.scanVolume(volume.mountPath, volumeId: volume.id)
    }
}
```

#### 4.2.4 数据库批量写入

```swift
func insertBatch(_ records: [FileRecord]) {
    // BEGIN TRANSACTION 包裹批量插入（50x 写入加速关键）
    try db.transaction {
        let stmt = try db.prepare("""
            INSERT OR REPLACE INTO files
                (volume_id, name, parent_path, size, mod_time, create_time, file_ext, is_dir)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """)
        for r in records {
            try stmt.run(r.volumeId, r.name, r.parentPath, r.size,
                         r.modTime, r.createTime, r.fileExt, r.isDir)
        }
    }
}
```

### 4.3 增量监控（Delta Watcher）

#### 4.3.1 APFS / HFS+ 内置盘——FSEvents

```swift
import CoreServices

class FSEventsWatcher {
    private var streamRef: FSEventStreamRef?

    func startWatching(paths: [String]) {
        let pathsToWatch = paths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        streamRef = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info!).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                watcher.handleEvents(paths: paths as! [String], flags: eventFlags, count: numEvents)
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,   // latency: 聚合 1 秒内的事件后批量处理
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |    // 文件级事件
                kFSEventStreamCreateFlagWatchRoot |     // 监控根路径变化
                kFSEventStreamCreateFlagNoDefer         // 不延迟首次事件
            )
        )

        FSEventStreamScheduleWithRunLoop(streamRef!, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue as CFString)
        FSEventStreamStart(streamRef!)
    }

    private func handleEvents(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        var updatePaths: [String] = []
        var deletedPaths: [String] = []

        for i in 0..<count {
            let flag = flags[i]
            let path = paths[i]
            if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                deletedPaths.append(path)
            } else {
                updatePaths.append(path)
            }
        }

        // 批量更新索引
        DispatchQueue.global(qos: .utility).async {
            DatabaseManager.shared.deleteFiles(paths: deletedPaths)
            DatabaseManager.shared.updateFiles(paths: updatePaths)
        }
    }
}
```

#### 4.3.2 exFAT / NTFS 外接硬盘——目录树 Hash 对比

> FSEvents 对 exFAT/NTFS 格式的外接硬盘覆盖不完整，需自行实现差异检测。

```swift
class ExternalDriveWatcher {

    /// 外接盘挂载时触发（由 DiskArbitration 回调调用）
    func onVolumeMounted(mountPath: String, volumeId: String) {
        DispatchQueue.global(qos: .background).async {
            // 1. 读取数据库中该 Volume 上次的文件快照
            let oldSnapshot = DatabaseManager.shared.getSnapshot(volumeId: volumeId)

            // 2. 遍历当前文件系统，生成新快照（path → modTime 字典）
            let newSnapshot = self.buildSnapshot(mountPath: mountPath)

            // 3. 对比差异
            let addedOrModified = newSnapshot.filter { path, modTime in
                oldSnapshot[path] != modTime
            }
            let deleted = oldSnapshot.keys.filter { newSnapshot[$0] == nil }

            // 4. 批量同步索引
            DatabaseManager.shared.deleteFiles(paths: Array(deleted))
            DatabaseManager.shared.upsertFiles(paths: Array(addedOrModified.keys), volumeId: volumeId)
        }
    }

    private func buildSnapshot(mountPath: String) -> [String: Double] {
        var snapshot: [String: Double] = [:]
        // 使用同样的 fts 遍历，仅收集 path → modTime
        // ...（实现同 FileSystemScanner）
        return snapshot
    }
}
```

### 4.4 搜索与过滤引擎

#### 4.4.1 搜索 SQL 构建

```swift
class SearchQueryBuilder {

    struct SearchParams {
        var keyword: String = ""
        var extensions: [String] = []     // ext: 语法
        var minSize: Int64? = nil          // size:> 语法
        var maxSize: Int64? = nil          // size:< 语法
        var afterDate: Double? = nil       // dm:> 语法
        var beforeDate: Double? = nil      // dm:< 语法
        var onlyFiles: Bool = false        // file: 语法
        var onlyFolders: Bool = false      // folder: 语法
        var pathContains: String? = nil    // path: 语法
        var volumeId: String? = nil        // 按介质过滤
    }

    func buildSQL(_ params: SearchParams) -> (sql: String, bindings: [Any]) {
        var conditions: [String] = []
        var bindings: [Any] = []

        // 关键词搜索：优先走 FTS5 索引
        if !params.keyword.isEmpty {
            conditions.append("files.id IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?)")
            bindings.append(escapeFTSQuery(params.keyword))
        }

        // 文件类型过滤
        if !params.extensions.isEmpty {
            let placeholders = params.extensions.map { _ in "?" }.joined(separator: ",")
            conditions.append("files.file_ext IN (\(placeholders))")
            bindings.append(contentsOf: params.extensions)
        }

        // 大小过滤
        if let minSize = params.minSize {
            conditions.append("files.size > ?")
            bindings.append(minSize)
        }
        if let maxSize = params.maxSize {
            conditions.append("files.size < ?")
            bindings.append(maxSize)
        }

        // 时间过滤
        if let after = params.afterDate {
            conditions.append("files.mod_time > ?")
            bindings.append(after)
        }
        if let before = params.beforeDate {
            conditions.append("files.mod_time < ?")
            bindings.append(before)
        }

        // 类型过滤
        if params.onlyFiles    { conditions.append("files.is_dir = 0") }
        if params.onlyFolders  { conditions.append("files.is_dir = 1") }

        // 路径过滤（参数化，防注入）
        if let path = params.pathContains {
            conditions.append("files.parent_path LIKE ?")
            bindings.append("%\(path)%")
        }

        // 介质过滤
        if let vid = params.volumeId {
            conditions.append("files.volume_id = ?")
            bindings.append(vid)
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT files.id, files.name, files.parent_path, files.size, files.mod_time, files.is_dir
            FROM files
            \(whereClause)
            ORDER BY files.name ASC
            LIMIT 100000
        """
        return (sql, bindings)
    }

    /// FTS5 特殊字符转义（防止 MATCH 语法报错）
    private func escapeFTSQuery(_ keyword: String) -> String {
        let escaped = keyword.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
```

#### 4.4.2 高级语法解析器

```swift
// 输入："汇报 size:>50MB ext:pdf"
// 输出：SearchParams { keyword="汇报", minSize=52428800, extensions=["pdf"] }

class SyntaxParser {
    func parse(_ input: String) -> SearchQueryBuilder.SearchParams {
        var params = SearchQueryBuilder.SearchParams()
        var keywordParts: [String] = []

        let tokens = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        for token in tokens {
            if token.hasPrefix("ext:") {
                params.extensions = token.dropFirst(4).components(separatedBy: ",")
                    .map { $0.lowercased().trimmingCharacters(in: .init(charactersIn: ".")) }
            } else if token.hasPrefix("size:>") {
                params.minSize = parseSize(String(token.dropFirst(6)))
            } else if token.hasPrefix("size:<") {
                params.maxSize = parseSize(String(token.dropFirst(6)))
            } else if token.hasPrefix("dm:") {
                parseDateRange(String(token.dropFirst(3)), into: &params)
            } else if token.hasPrefix("path:") {
                params.pathContains = String(token.dropFirst(5))
            } else if token == "folder:" {
                params.onlyFolders = true
            } else if token == "file:" {
                params.onlyFiles = true
            } else {
                keywordParts.append(token)
            }
        }
        params.keyword = keywordParts.joined(separator: " ")
        return params
    }

    private func parseSize(_ s: String) -> Int64 {
        let units: [(String, Int64)] = [("TB", 1_099_511_627_776), ("GB", 1_073_741_824),
                                        ("MB", 1_048_576), ("KB", 1024), ("B", 1)]
        for (suffix, multiplier) in units {
            if s.uppercased().hasSuffix(suffix) {
                let num = Double(s.dropLast(suffix.count)) ?? 0
                return Int64(num * Double(multiplier))
            }
        }
        return Int64(s) ?? 0
    }
}
```

### 4.5 权限检测与引导

```swift
import Security

class PermissionManager {

    /// 检测全磁盘访问权限（Full Disk Access）
    /// 原理：尝试读取 TCC.db，有权限才能成功
    static func hasFDA() -> Bool {
        let testPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: testPath)
    }

    /// 引导用户开启 FDA（跳转系统设置）
    static func openFDASettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
```

---

## 五、UI/UX 详细设计规范

### 5.1 设计原则

1. **功能优先、极简高效**：所有元素服务于「快速搜索、快速定位文件」，无多余装饰
2. **1:1 对标 Everything**：操作逻辑、菜单结构、快捷键对标 Windows Everything，降低学习成本
3. **完全适配 macOS 规范**：自动跟随系统浅色/深色模式，使用原生语义化颜色

### 5.2 主界面布局（对标 Everything 截图）

```
┌─────────────────────────────────────────────────────────────────────┐
│  ● ● ●  [搜索范围▼]  [🔍 搜索文件名或输入语法... (Cmd+F)       ] [≡] │  ← 顶部工具栏
├─────────────────────────────────────────────────────────────────────┤
│  名称 ↑                │ 路径                  │ 大小    │ 修改时间  │  ← 列头（可点击排序）
├─────────────────────────────────────────────────────────────────────┤
│  📄 **汇**报Q1.pdf     │ /Users/admin/Desktop  │ 2.3 MB  │ 2026/03/01│
│  📄 **汇**报Q2.xlsx    │ /Volumes/MyDisk/工作  │ 1.1 MB  │ 2026/02/15│  ← 斑马线交替背景
│  📁 季度**汇**报       │ /Users/admin/文档     │  —      │ 2026/01/20│
│  ...（虚拟滚动，百万条无卡顿）                                        │
├─────────────────────────────────────────────────────────────────────┤
│  3 个对象                    索引中：内置硬盘 78%...     选中：0 个  │  ← 底部状态栏
└─────────────────────────────────────────────────────────────────────┘
```

### 5.3 各区域详细规范

#### 顶部工具栏

| 元素 | 规范 |
|------|------|
| 窗口控制 | 标准 macOS 红黄绿按钮，无自定义 |
| 搜索范围下拉 | 可选：全部介质 / 内置硬盘 / 各外接介质名称 |
| 搜索输入框 | `NSSearchField`，占据工具栏 80% 宽度，聚焦快捷键 `Cmd+F` |
| 菜单栏按钮 | 高级过滤（可折叠侧边栏开关）、视图切换、设置 |

#### 结果表格（核心区域）

| 属性 | 规范 |
|------|------|
| 控件类型 | `NSTableView`（**禁止使用 SwiftUI List**） |
| 默认列（顺序固定） | 名称、路径、大小、修改时间 |
| 名称列 | 文件图标（`NSWorkspace.icon(forFile:)`） + 文件名，关键词黄色高亮 |
| 路径列 | 显示父目录完整路径（去除文件名部分） |
| 大小列 | 右对齐，格式：`XX KB` / `XX.X MB` / `XX.X GB`，文件夹显示 `—` |
| 修改时间列 | 格式：`yyyy/MM/dd HH:mm` |
| 虚拟滚动 | 实现 `NSTableView` 的 `reloadData` + `visibleRows` 虚拟化，仅渲染可见行 |
| 斑马线 | `usesAlternatingRowBackgroundColors = true` |
| 列交互 | 点击列头正反排序、拖拽调整列宽、列宽持久化 |
| 右键菜单 | 见 5.4 节 |

#### 底部状态栏

| 位置 | 内容 |
|------|------|
| 左侧 | `x 个对象`（实时反映当前过滤后的总数） |
| 中间 | 索引状态：`正在监控...` / `正在扫描 MyDisk (45%)...` / `索引就绪` |
| 右侧 | 已选中文件数量 / 选中文件完整路径 |

### 5.4 交互规范

#### 键盘快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+F` | 全局聚焦搜索框（主窗口激活状态下） |
| `双击 Option` | 全局唤出主窗口（需辅助功能权限） |
| `Enter` | 用系统默认程序打开所选文件 |
| `Cmd+Enter` | 在 Finder 中显示所选文件 |
| `Space` | QuickLook 预览 |
| `Delete` | 移到废纸篓 |
| `Cmd+C` | 复制文件 |
| `Cmd+Shift+C` | 复制完整路径 |
| `Cmd+A` | 全选 |
| `Esc` | 清空搜索框 |

#### 右键菜单结构

```
打开
在访达中显示                    Cmd+Enter
---
复制完整路径                    Cmd+Shift+C
复制所在文件夹路径
---
复制文件
移到废纸篓                      Delete
---
（多选时显示：批量操作 x 个文件）
```

### 5.5 视觉规范

| 属性 | 规范 |
|------|------|
| 字体 | 英文：SF Pro；中文：PingFang SC |
| 字号 | 表格行：13px；搜索框：14px；状态栏：12px；列标题：13px 加粗 |
| 窗口默认尺寸 | 1200 × 700 px |
| 窗口最小尺寸 | 800 × 500 px |
| 主题 | 自动跟随系统浅色/深色模式，使用 `NSColor.controlBackgroundColor` 等语义化颜色 |
| 关键词高亮 | 匹配字符用 `NSColor.systemYellow` 背景色高亮 |
| 行高 | 默认 22px（紧凑模式 18px，舒适模式 26px，可配置） |

---

## 六、安全审查要点（供 CodeX 审查）

### 6.1 沙盒与权限

```xml
<!-- QuickSearch.entitlements -->
<!-- App Sandbox 必须关闭，否则无法全盘扫描 -->
<!-- com.apple.security.app-sandbox 不得出现，或显式设为 false -->

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 无沙盒标识即为关闭沙盒 -->
    <!-- 仅保留必要权限 -->
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
</dict>
</plist>
```

### 6.2 SQL 注入防护（强制要求）

```swift
// ✅ 正确：参数化查询
let stmt = try db.prepare("SELECT * FROM files WHERE name LIKE ?")
try stmt.run("%\(userInput)%")

// ❌ 错误：禁止字符串拼接
let sql = "SELECT * FROM files WHERE name LIKE '%\(userInput)%'"  // SQL 注入风险
```

### 6.3 资源限制

```swift
// 扫描线程必须使用低 QoS
DispatchQueue.global(qos: .utility)   // ✅
DispatchQueue.global(qos: .userInitiated)  // ❌ 会占满 CPU

// 内存水位控制：每积累 10,000 条立即 flush
if batch.count >= 10_000 {
    flushBatch(&batch)  // 释放内存
}
```

### 6.4 FSEvents 安全使用

```swift
// 必须设置 FTS_XDEV 防止跨设备递归（防止进入网络挂载点导致无限扫描）
let flags = FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV  // ✅ 不跨越文件系统边界
```

---

## 七、开发里程碑

| 阶段 | 核心目标 | 核心交付物 | 验收标准 |
|------|----------|------------|----------|
| **M1（2周）：引擎地基** | 数据库设计 + 文件遍历底层 | SQLite 数据库结构；fts 遍历模块；批量写入模块 | 成功遍历 1TB 内置盘并存入 SQLite，耗时 ≤ 3 分钟；无崩溃无数据丢失 |
| **M2（1.5周）：实时监控** | FSEvents + 外接硬盘适配 | FSEvents 监控模块；外接盘 Hash 对比模块；DiskArbitration 挂载监听 | 新建/删除文件后 ≤ 1s 完成索引同步；外接 U 盘插入自动识别并触发索引 |
| **M3（1.5周）：极限 UI** | 渲染百万条数据的界面 | AppKit 主界面；虚拟化 NSTableView；搜索防抖；关键词高亮 | 快速滚动 100 万条数据无掉帧；输入关键词 ≤ 100ms 出结果 |
| **M4（1周）：搜索增强** | 过滤语法 + 多介质搜索 | 语法解析器；过滤 SQL 构建器；多介质切换 UI | 支持 `ext:`/`size:`/`dm:`/`path:` 语法；组合过滤 ≤ 200ms |
| **M5（1周）：体验打磨** | 权限引导 + 右键菜单 + 快捷键 | 权限引导流程；完整右键菜单；键盘快捷键；底部状态栏 | FDA 引导流程顺畅；所有快捷键生效；双击/空格行为与 Finder 一致 |

---

## 八、风险与应对措施

| 风险 | 描述 | 应对措施 |
|------|------|----------|
| **FDA 权限获取困难** | 用户无法正确开启全磁盘访问，导致无法遍历全盘 | 制作清晰图文引导，一键跳转系统设置；无权限目录自动跳过并记录日志 |
| **HDD 大硬盘性能** | 2TB HDD 由于随机 IO 特性，索引可能超过预期时间 | 针对 HDD 优化 IO 策略（顺序读取），提供进度展示，设置节能模式降低影响 |
| **exFAT 外接盘监控** | FSEvents 对 exFAT/NTFS 覆盖不完整，增量更新可能不准确 | 外接盘挂载时全量 Hash 对比，保证一致性；定期触发校验（每 30 分钟） |
| **FTS5 中文匹配** | unicode61 分词器对中文按字符分割，可能导致子词匹配不准确 | P1 阶段集成 jieba 分词或拼音搜索插件；P0 阶段 LIKE 作为 FTS5 的补充兜底方案 |
| **macOS API 版本变化** | 新版 macOS 可能调整 TCC 权限检测方式 | 采用系统公开 API，避免私有 API；做好版本判断，不同版本使用对应适配逻辑 |
| **索引数据一致性** | 高频文件变更、外接存储反复插拔，可能导致索引与实际不一致 | 提供手动重建索引入口；介质挂载时自动执行增量校验 |

---

## 附录一：项目文件结构参考

```
QuickSearch/
├── App/
│   ├── AppDelegate.swift           # 应用入口，权限检测，菜单栏图标
│   └── MainWindowController.swift  # 主窗口控制器
├── UI/
│   ├── MainViewController.swift    # 主界面布局
│   ├── ResultTableView.swift       # 虚拟化 NSTableView
│   ├── SearchBarView.swift         # 搜索输入框（含防抖）
│   ├── StatusBarView.swift         # 底部状态栏
│   └── PermissionGuideWindow.swift # FDA 权限引导窗口
├── Engine/
│   ├── FileSystemScanner.swift     # fts 底层遍历
│   ├── FSEventsWatcher.swift       # FSEvents 文件系统监控
│   ├── ExternalDriveWatcher.swift  # 外接盘 Hash 对比
│   └── DiskManager.swift           # DiskArbitration 介质管理
├── Database/
│   ├── DatabaseManager.swift       # SQLite 连接管理
│   ├── SchemaManager.swift         # 数据库表结构创建与迁移
│   └── QueryBuilder.swift          # SQL 查询构建器
├── Search/
│   ├── SearchEngine.swift          # 搜索入口，协调 FTS 与过滤
│   ├── SyntaxParser.swift          # 高级搜索语法解析器
│   └── FilterBuilder.swift         # 过滤条件 SQL 构建
├── Model/
│   ├── FileRecord.swift            # 文件元数据模型
│   ├── VolumeInfo.swift            # 存储介质信息模型
│   └── SearchParams.swift          # 搜索参数模型
├── Utilities/
│   ├── PermissionManager.swift     # FDA 权限检测
│   ├── LogManager.swift            # 日志管理
│   └── SizeFormatter.swift         # 文件大小格式化
└── Resources/
    ├── QuickSearch.entitlements     # 无沙盒配置
    └── Assets.xcassets
```

---

## 附录二：高级搜索语法规范（对标 Everything）

| 语法 | 说明 | 示例 |
|------|------|------|
| `ext:xxx` | 按文件后缀过滤（支持逗号分隔多个） | `ext:pdf` / `ext:zip,rar,7z` |
| `size:>xxx` | 文件大于指定大小 | `size:>50MB` |
| `size:<xxx` | 文件小于指定大小 | `size:<1GB` |
| `size:xxx..yyy` | 文件大小在区间内 | `size:1MB..100MB` |
| `dm:>yyyy-MM-dd` | 修改时间晚于指定日期 | `dm:>2026-01-01` |
| `dm:yyyy-MM-dd..yyyy-MM-dd` | 修改时间在区间内 | `dm:2026-01-01..2026-03-01` |
| `path:xxx` | 路径包含指定字符串 | `path:~/Desktop` |
| `folder:` | 仅搜索文件夹 | `folder: 项目` |
| `file:` | 仅搜索文件 | `file: 报告` |
| `*` | 通配符，匹配任意字符 | `*.mp4` |
| `?` | 通配符，匹配单个字符 | `0?.zip` |

**组合示例**：`汇报 size:>50MB ext:pdf` → 搜索文件名含"汇报"、大于 50MB 的 PDF 文件

---

## 附录三：术语说明

| 术语 | 说明 |
|------|------|
| FSEvents | macOS 原生文件系统事件监控框架（CoreServices） |
| FTS5 | SQLite 全文搜索扩展，实现高性能文件名搜索 |
| fts/dirent | POSIX 标准文件系统遍历 C API，性能远高于 FileManager |
| DiskArbitration | macOS 原生磁盘管理框架，实时监控介质挂载/卸载 |
| WAL | SQLite Write-Ahead Logging，大幅提升写入并发性能 |
| FDA | Full Disk Access（全磁盘访问），macOS 最高级别文件系统权限 |
| UTI | Uniform Type Identifier，macOS 统一文件类型标识符 |
| XPC | macOS 原生进程间通信框架（P1 阶段后台进程拆分使用） |

---

*文档编制日期：2026-03-08*
*设计理念：天下武功，唯快不破。克制做加法，专注把"搜文件名"做到极致。*
