# QuickSearch for Mac — 产品需求与技术实现蓝图

**文档版本**：V1.1
**编制日期**：2026-03-08
**文档状态**：审查调整版（基于 V1.0 技术审核修订）
**目标读者**：
- **Gemini**：需求合规性审核、产品逻辑把控
- **ClaudeCode**：核心逻辑与代码实现
- **CodeX**：代码安全、性能审查与规范合规

---

## 修订记录

| 版本 | 日期 | 修订内容 | 修订人 |
|------|------|----------|--------|
| V1.0 | 2026-03-08 | 初稿，综合多方需求文档编制 | 需求方 |
| V1.1 | 2026-03-08 | 技术审核修订：修复 FTS5 触发器性能陷阱、内存泄漏、缺失函数实现、FDA 检测兼容性、FTS 前缀匹配问题；删除过度设计条目 | 审核方 |

---

## V1.0 → V1.1 主要审核修订说明

> 本节列出 V1.0 中存在的技术问题及修订理由，供 Gemini/CodeX 复查。

| 问题编号 | 问题描述 | 修订方案 |
|----------|----------|----------|
| **T-01** | **FTS5 触发器与批量写入存在严重性能冲突**：V1.0 同时使用了「触发器自动同步 FTS」和「事务批量插入」，每次 `INSERT` 触发器都会触发一次 FTS 写入，1 万条批量写入实际触发 1 万次 FTS 操作，完全抵消批量事务的性能优势 | 初始全量索引构建阶段：禁用触发器，批量写入完成后执行 `INSERT INTO files_fts(files_fts) VALUES('rebuild')` 一次性重建 FTS 索引；增量更新阶段：单条变更量小，触发器可正常使用 |
| **T-02** | **FSEvents 回调中 `Unmanaged.passRetained(self)` 内存泄漏**：`passRetained` 增加引用计数但从不释放，导致 `FSEventsWatcher` 实例永远无法被释放 | 改为 `passUnretained(self)`，由调用方持有强引用；或在 `stopWatching` 时显式调用 `release()` 平衡引用计数 |
| **T-03** | **`SyntaxParser` 中 `parseDateRange` 函数引用但未实现**：V1.0 代码中调用了 `parseDateRange` 但未提供实现，编译直接报错 | 补充完整的 `parseDateRange` 函数实现 |
| **T-04** | **FTS5 MATCH 使用精确短语匹配，无法实现前缀搜索**：搜索"汇报"无法匹配"季度汇报总结"，与 Everything 的模糊匹配体验不符 | MATCH 查询使用 `"keyword*"` 前缀匹配模式；多关键词时拆分为多个 `AND "word*"` 组合 |
| **T-05** | **`INSERT OR REPLACE` 触发 DELETE+INSERT 双重 FTS 操作**：SQLite 的 `REPLACE` 实际是 `DELETE` 旧记录再 `INSERT` 新记录，触发两次触发器，FTS 写入量翻倍 | 全量构建使用 `INSERT` + 关闭触发器；增量更新使用 `INSERT OR IGNORE` + 单独 `UPDATE` 语句 |
| **T-06** | **FDA 权限检测依赖 TCC.db 路径，在不同 macOS 版本下不稳定**：macOS 14+ 对 TCC.db 路径和权限有所调整，纯路径判断可能误报/漏报 | 改用 `open()` 系统调用尝试读取 `/Library/Application Support/com.apple.TCC/TCC.db`，通过 `errno` 判断是否为 `EACCES`；同时保留路径检测作为兜底 |
| **T-07** | **豆包版 V1.0 的"索引数据加密存储"属于 MVP 过度设计**：加密索引需要密钥管理机制，大幅增加复杂度，与 P0 范围不符 | 移除 P0 中的索引加密需求，降级为 P2 可选功能 |
| **T-08** | **豆包版 V1.0 的多进程 XPC 架构在 MVP 阶段过早引入**：XPC 进程间通信调试复杂，MVP 阶段应保持单进程验证核心功能 | 明确 MVP 采用单进程分层架构，XPC 后台进程拆分列为 P1 阶段目标 |

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

### 1.3 开发环境与技术选型

| 项目 | 选型 | 理由 |
|------|------|------|
| 开发语言 | Swift 5.10+，性能模块混编 C/POSIX | 原生性能、内存安全、可无缝桥接所有系统 API |
| 最低系统 | macOS 12.0 Monterey | 覆盖主流用户群，`SMAppService` 在 macOS 13+ 用于开机自启 |
| 芯片支持 | Apple Silicon M 系列 + Intel Universal Binary | 无需 Rosetta 转译，原生双架构 |
| UI 框架 | **AppKit**（**绝对禁止在主数据列表使用 SwiftUI**） | NSTableView 支持虚拟化，百万级数据 60fps 滚动；SwiftUI List 无法实现 |
| 文件遍历 | BSD `fts_open` / `fts_read` + `stat` | 比 `FileManager.enumerator` 快 10x+，直接操作内核级 inode |
| 索引存储 | SQLite 3（系统自带）+ FTS5 全文扩展 | 无额外依赖，FTS5 毫秒级全文检索，千万级文件游刃有余 |
| 文件监控 | FSEvents（CoreServices） | macOS 原生文件系统事件框架，低延迟低资源占用 |
| 介质管理 | DiskArbitration 框架 | 实时监控挂载/卸载，获取介质详细信息 |
| 文件预览 | QuickLook 框架 | 与 Finder 行为完全一致，无学习成本 |

---

## 二、功能需求（按优先级分级）

> P0：MVP 必须实现；P1：高优先级，第二阶段实现；P2：低优先级，后续迭代

### 2.1 核心搜索功能（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **实时极速搜索** | 用户输入关键词，实时触发搜索，无需回车确认，即搜即显 | 1. 输入防抖延迟 ≤ 50ms，结果实时刷新；2. 默认仅匹配文件名/文件夹名，不匹配文件内容；3. 大小写不敏感；4. 支持空格分隔的多关键词「与」逻辑 |
| **匹配模式** | 支持多种匹配模式 | 1. 子串模糊匹配（输入"汇报"可命中"季度汇报总结"）；2. 通配符：`*`（任意字符）、`?`（单个字符）；3. P1 阶段支持正则表达式 |
| **搜索对象切换** | 切换搜索对象：全部 / 仅文件 / 仅文件夹 | 切换后实时过滤，无需重新触发搜索 |
| **搜索范围限定** | 指定搜索根目录，仅在指定范围内执行搜索 | 1. 支持手动输入路径、拖拽文件夹指定范围；2. P1 阶段支持保存常用范围为预设 |

### 2.2 高级过滤功能（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **文件类型过滤** | 按文件后缀名或预设类型过滤 | 1. 预设类型：视频、音频、图片、文档、压缩包、代码文件；2. 支持自定义后缀，多后缀组合（如 `.zip,.rar,.7z`） |
| **文件大小过滤** | 按文件大小范围过滤 | 1. 预设区间：空文件、< 1MB、1MB–100MB、100MB–1GB、> 1GB；2. 支持自定义区间，可选 B/KB/MB/GB/TB 单位 |
| **修改时间过滤** | 按文件修改时间过滤 | 1. 预设：今天、昨天、近 7 天、近 30 天、今年；2. 支持自定义时间区间，精确到分钟 |
| **高级搜索语法** | 在搜索框直接输入语法实现过滤，对标 Everything | P0 阶段支持 `ext:`、`size:`、`dm:`、`path:`、`folder:`、`file:`（详见附录二） |
| **组合过滤** | 所有过滤条件可组合使用 | 修改任意过滤条件后实时生效，结果同步更新 |

### 2.3 索引管理功能（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **全量索引构建** | 首次启动自动扫描，构建全量文件元数据索引 | 1. 索引字段：文件名、父目录路径、文件大小、修改时间、创建时间、文件后缀、是否为文件夹；2. 2TB SSD ≤ 5 分钟；3. 支持暂停/继续/取消，实时显示进度与已扫描文件数 |
| **增量索引更新** | 监控文件系统变更，实时更新索引 | 1. 基于 FSEvents 框架；2. 文件变更后 ≤ 1s 完成索引同步；3. 系统唤醒、外接存储重新挂载后自动执行增量校验 |
| **外接存储特殊处理** | exFAT/NTFS 等格式的外接硬盘，FSEvents 覆盖不完整 | 针对外接存储实现「目录树快照 modTime 对比」算法，挂载时触发全量比对，找出变更后同步索引 |
| **索引持久化** | 索引数据本地持久化，支持手动重建和清理 | 1. 按存储介质分别管理索引；2. 外接存储卸载后保留索引，重新挂载后自动激活；3. 支持手动触发全量重建 |
| **排除规则** | 支持排除指定目录，减少无效索引 | 1. 默认排除：系统目录（`/System`、`/private`）、隐藏目录；2. 支持用户自定义排除路径 |

### 2.4 存储介质管理（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **自动识别介质** | 自动识别内置硬盘和所有挂载的外接存储 | 基于 DiskArbitration 框架，实时监控挂载/卸载事件，显示介质名称、容量、文件系统类型 |
| **外接存储策略** | 外接存储挂载后提示用户选择处理方式 | 弹窗提示三选一：「本次索引」/「永久自动索引」/「忽略该介质」 |
| **多介质并行搜索** | 同时搜索多个存储介质 | 主界面支持切换：全部介质 / 仅内置硬盘 / 指定外接介质；多介质并行查询，结果合并展示 |

### 2.5 结果展示与操作（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **结果列表展示** | 以表格形式展示，对标 Everything 界面 | 1. 默认 4 列（顺序固定）：**名称、路径、大小、修改时间**；2. 支持列宽调整、列顺序拖拽、列头点击排序；3. 关键词匹配部分高亮；4. 支持百万级结果虚拟滚动，60fps 无卡顿 |
| **文件操作** | 鼠标/键盘快速操作 | 1. 双击：系统默认程序打开；2. `Cmd+Enter`：在 Finder 中显示；3. `Space`：QuickLook 预览；4. `Delete`：移到废纸篓 |
| **右键菜单** | 右键提供完整操作项 | 打开、在访达中显示、复制完整路径、复制文件、重命名、移到废纸篓（多选批量支持） |
| **QuickLook 预览** | 空格键触发原生快速预览 | 基于 macOS 原生 QuickLook 框架，与 Finder 行为完全一致 |

### 2.6 系统权限与适配（P0）

| 功能点 | 详细描述 | 验收标准 |
|--------|----------|----------|
| **全磁盘访问权限引导** | 首次启动检测并引导开启 FDA | 1. 检测未授权时弹出图文引导窗口；2. 提供按钮一键跳转系统设置；3. 用户授权后自动触发初始索引，无需重启 |
| **后台常驻** | 支持后台运行以保证索引实时性 | 1. 主窗口关闭后可选：后台常驻（菜单栏图标）或完全退出；2. 菜单栏图标支持：快速打开、暂停索引、查看状态、退出 |
| **开机自启** | 用户可设置登录后自动后台启动 | macOS 13+：`SMAppService`；macOS 12 兼容：`LaunchAgent` plist |

### 2.7 辅助功能（P1/P2）

1. **个性化设置（P1）**：快捷键自定义（预设 Everything 兼容方案）、UI 主题、行高
2. **搜索历史与书签（P1）**：自动记录搜索历史，支持保存常用搜索为书签，一键复用
3. **日志与故障排查（P1）**：分级记录运行/索引/错误日志，支持故障自检与手动导出
4. **XPC 后台进程拆分（P1）**：主进程与索引进程解耦，主界面崩溃不影响索引持续运行
5. **索引数据加密存储（P2）**：可选密码保护，防止未授权访问索引内容
6. **自动更新（P2）**：检测并一键升级，可关闭完全离线运行

---

## 三、非功能需求

### 3.1 性能指标（强制达标，区分运行状态）

| 指标 | 目标值 | 适用状态 |
|------|--------|----------|
| 单关键词搜索响应 | ≤ 100ms | 百万级文件索引，主界面运行 |
| 多条件组合搜索响应 | ≤ 200ms | 百万级文件索引，主界面运行 |
| 2TB SSD 全量索引构建 | ≤ 5 分钟 | 初始扫描阶段 |
| 2TB HDD 全量索引构建 | ≤ 15 分钟 | 初始扫描阶段 |
| 单文件变更索引更新延迟 | ≤ 1s | 增量监控阶段 |
| 后台空闲内存占用 | ≤ 100MB | 索引完成，无搜索请求 |
| 后台空闲 CPU 占用 | ≤ 1% | 索引完成，无搜索请求 |
| 索引构建峰值 CPU | ≤ 30% | 仅在初始扫描阶段 |
| 索引构建峰值内存 | ≤ 300MB | 仅在初始扫描阶段 |
| 主界面运行内存 | ≤ 150MB | 正常搜索操作中 |

> **注（审核修订）**：后台空闲 CPU ≤ 1% 与索引构建峰值 CPU ≤ 30% 适用于不同状态，不可同时评测，已在表格中明确区分。

### 3.2 稳定性需求

1. 崩溃率 ≤ 0.1%，无内存泄漏，连续运行 7×24 小时无异常
2. 程序异常退出或系统强制关机后，SQLite WAL 模式保证索引数据不损坏，重启后自动恢复
3. 异常场景（无权限目录、损坏介质、中途卸载外接硬盘、磁盘满）下程序不崩溃，给出友好提示

### 3.3 安全性需求

1. 索引数据完全本地存储，**不上传任何云端**，程序无多余网络请求
2. **App Sandbox 必须关闭**，沙盒应用无法访问全盘文件系统
3. 所有用户输入的搜索关键词必须使用**参数化查询**，严禁 SQL 字符串拼接

---

## 四、详细技术实现路径

> 本章节为 ClaudeCode 核心实现指引，CodeX 审查重点章节。

### 4.1 整体架构

采用**单进程分层架构**（MVP/P0 阶段），P1 阶段可拆分 XPC 后台进程。

```
┌──────────────────────────────────────────────────┐
│                    UI 层 (AppKit)                 │
│    NSWindow / NSTableView / NSSearchField         │
└──────────────────────┬───────────────────────────┘
                       │ ViewModel (Combine/Observable)
┌──────────────────────▼───────────────────────────┐
│               业务逻辑层                          │
│    SearchEngine / SyntaxParser / BookmarkManager  │
└──────┬───────────────┬──────────────┬────────────┘
       │               │              │
┌──────▼──────┐  ┌─────▼──────┐  ┌───▼──────────┐
│  索引引擎层  │  │ 文件监控层 │  │ 介质管理层   │
│ SQLite+FTS5 │  │ FSEvents   │  │DiskArbitration│
└──────┬──────┘  └─────┬──────┘  └───┬──────────┘
       │               │              │
┌──────▼───────────────▼──────────────▼───────────┐
│                 系统适配层                        │
│    BSD fts/stat / C POSIX API / TCC 权限检测      │
└─────────────────────────────────────────────────┘
```

### 4.2 索引引擎（The Indexer）

#### 4.2.1 数据库设计

```sql
-- ============================================================
-- 性能优化 PRAGMA（程序每次启动时执行）
-- ============================================================
PRAGMA journal_mode = WAL;        -- Write-Ahead Logging，并发写入性能大幅提升
PRAGMA synchronous   = NORMAL;    -- 平衡性能与崩溃安全（WAL 模式下 NORMAL 已足够安全）
PRAGMA cache_size    = -65536;    -- 64MB 页面缓存（负数=KB，正数=页数）
PRAGMA temp_store    = MEMORY;    -- 临时排序/分组表存内存，减少磁盘 IO

-- ============================================================
-- 核心元数据表
-- ============================================================
CREATE TABLE IF NOT EXISTS files (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    volume_id    TEXT    NOT NULL,       -- 存储介质唯一 ID（/dev/disk2s1 等 BSD 设备路径）
    name         TEXT    NOT NULL,       -- 文件名（不含路径，FTS 搜索目标）
    parent_path  TEXT    NOT NULL,       -- 父目录完整路径（UI 展示路径列使用）
    size         INTEGER DEFAULT 0,      -- 文件字节大小；文件夹填 0（不实时计算目录总大小）
    mod_time     REAL    NOT NULL,       -- 修改时间 Unix timestamp（double 精度）
    create_time  REAL    DEFAULT 0,      -- 创建时间 Unix timestamp
    file_ext     TEXT    DEFAULT '',     -- 后缀名（小写，不含点号，如 "pdf"）
    is_dir       INTEGER DEFAULT 0      -- 1=文件夹，0=文件
);

-- 常用查询字段索引（覆盖过滤条件的所有列）
CREATE INDEX IF NOT EXISTS idx_files_volume   ON files(volume_id);
CREATE INDEX IF NOT EXISTS idx_files_ext      ON files(file_ext);
CREATE INDEX IF NOT EXISTS idx_files_size     ON files(size);
CREATE INDEX IF NOT EXISTS idx_files_mod_time ON files(mod_time);
CREATE INDEX IF NOT EXISTS idx_files_parent   ON files(parent_path);
-- 注：name 列不单独建 B-Tree 索引，全文搜索走 FTS5 虚拟表更高效

-- ============================================================
-- FTS5 全文搜索虚拟表
-- 采用"外部内容表"模式（content='files'），FTS 索引不重复存储 name 文本，
-- 仅存储倒排索引，节省约 40% 磁盘空间
-- ============================================================
CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
    name,
    content     = 'files',          -- 内容来源于 files 表
    content_rowid = 'id',           -- 关联主键列
    tokenize    = 'unicode61 remove_diacritics 2'
    -- unicode61：支持 Unicode 规范化，正确处理中文、日文、韩文字符
    -- remove_diacritics 2：移除变音符号，实现跨语言模糊匹配
    -- ⚠️ 中文拼音搜索需 P1 阶段集成 libpinyin 自定义分词器
);

-- ============================================================
-- FTS 同步触发器（仅用于增量更新阶段的单条操作）
-- ⚠️ 重要：全量批量写入时必须先 DROP 这三个触发器，
--          批量完成后执行 INSERT INTO files_fts(files_fts) VALUES('rebuild')
--          再重新创建触发器。详见 4.2.4 节。
-- ============================================================
CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
    INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
END;
CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
END;
CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE OF name ON files BEGIN
    INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
    INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
END;

-- ============================================================
-- 存储介质管理表
-- ============================================================
CREATE TABLE IF NOT EXISTS volumes (
    volume_id    TEXT PRIMARY KEY,        -- BSD 设备路径，如 /dev/disk2s1
    volume_name  TEXT NOT NULL,           -- 用户可见名称，如 "My Passport"
    mount_path   TEXT NOT NULL,           -- 当前挂载路径，如 /Volumes/My Passport
    fs_type      TEXT NOT NULL,           -- 文件系统：APFS / HFS+ / exFAT / NTFS / FAT32
    total_size   INTEGER DEFAULT 0,
    is_external  INTEGER DEFAULT 0,       -- 1=外接介质
    is_indexed   INTEGER DEFAULT 0,       -- 1=已完成全量索引
    last_scan    REAL    DEFAULT 0,       -- 上次全量扫描的 Unix 时间戳
    index_policy TEXT    DEFAULT 'auto'   -- auto（永久自动索引）/ once / ignore
);

-- ============================================================
-- 用户自定义排除规则表
-- ============================================================
CREATE TABLE IF NOT EXISTS exclude_rules (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_type  TEXT NOT NULL,   -- path（路径前缀匹配）/ ext（后缀匹配）/ name（文件名匹配）
    pattern    TEXT NOT NULL,   -- 规则内容，如 "/System" / "tmp" / ".DS_Store"
    is_enabled INTEGER DEFAULT 1
);
```

#### 4.2.2 初始极速扫描实现

```swift
// ============================================================
// 核心约束：禁止使用 FileManager.enumerator（高层 API 底层经过多次 Objective-C 桥接，慢 10x+）
// 必须使用 POSIX BSD fts_open / fts_read，直接操作内核 VFS 层
// ============================================================

import Darwin   // 包含 fts.h、stat.h、dirent.h

class FileSystemScanner {

    private let kBatchSize = 10_000  // 内存水位控制：每 1 万条 flush 一次

    func scanVolume(_ mountPath: String, volumeId: String, progressHandler: ((Int) -> Void)? = nil) {
        // fts_open 要求 C 字符串数组，以 nil 结尾
        let pathBytes = (mountPath as NSString).utf8String!
        var paths: [UnsafeMutablePointer<CChar>?] = [strdup(pathBytes), nil]
        defer { paths.forEach { free($0) } }

        // FTS_NOCHDIR : 不改变进程工作目录（线程安全要求）
        // FTS_PHYSICAL : 不跟随符号链接，防止循环递归
        // FTS_XDEV     : 不跨越文件系统边界，防止意外扫描网络挂载点
        guard let fts = fts_open(&paths, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, nil) else {
            LogManager.shared.error("fts_open failed for \(mountPath): \(String(cString: strerror(errno)))")
            return
        }
        defer { fts_close(fts) }

        var batch: [FileRecord] = []
        batch.reserveCapacity(kBatchSize)
        var totalCount = 0

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)

            switch info {
            case FTS_F,   // 普通文件
                 FTS_D:   // 目录（进入时）
                let name = String(cString: entry.pointee.fts_name)
                let path = String(cString: entry.pointee.fts_path)

                // 跳过隐藏文件（默认行为，可由用户在设置中关闭）
                if name.hasPrefix(".") { continue }

                // 检查排除规则，若为被排除目录则跳过整个子树
                if isExcluded(path: path, name: name) {
                    if info == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                    continue
                }

                let st = entry.pointee.fts_statp!.pointee
                batch.append(FileRecord(
                    volumeId:   volumeId,
                    name:       name,
                    parentPath: (path as NSString).deletingLastPathComponent,
                    size:       info == FTS_D ? 0 : Int64(st.st_size),
                    modTime:    Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                    createTime: Double(st.st_birthtimespec.tv_sec),
                    fileExt:    info == FTS_D ? "" : (name as NSString).pathExtension.lowercased(),
                    isDir:      info == FTS_D ? 1 : 0
                ))
                totalCount += 1

                // 达到批量上限立即 flush，释放内存，防止峰值超过 300MB
                if batch.count >= kBatchSize {
                    DatabaseManager.shared.insertBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                    progressHandler?(totalCount)
                }

            case FTS_DP:  // 目录（离开时），忽略
                break

            case FTS_ERR, FTS_DNR:  // 无权限或读取错误，静默跳过，记录日志
                LogManager.shared.warn("Skipped (no permission): \(String(cString: entry.pointee.fts_path))")

            default:
                break
            }
        }

        // flush 剩余数据
        if !batch.isEmpty {
            DatabaseManager.shared.insertBatch(batch)
            progressHandler?(totalCount)
        }
    }
}
```

#### 4.2.3 多线程扫描策略

```swift
// 每个 Volume 独立并发扫描，设置 .utility QoS 避免影响用户操作
// ⚠️ 不使用 .userInitiated / .userInteractive，避免风扇狂转

let group   = DispatchGroup()
let queue   = DispatchQueue(label: "com.quicksearch.scanner",
                            qos: .utility,
                            attributes: .concurrent)

for volume in volumesToScan {
    group.enter()
    queue.async {
        defer { group.leave() }
        FileSystemScanner().scanVolume(volume.mountPath, volumeId: volume.id) { count in
            DispatchQueue.main.async {
                self.updateProgress(volume: volume, scannedCount: count)
            }
        }
    }
}

group.notify(queue: .main) {
    self.onAllVolumesScanComplete()
}
```

#### 4.2.4 批量写入策略（关键性能修订——修复 T-01/T-05）

```swift
// ============================================================
// ⚠️ 全量索引构建的正确流程（解决 T-01 触发器性能陷阱）：
//
//   1. 构建开始前：DROP 三个 FTS 同步触发器
//   2. 事务批量写入 files 表（无触发器干扰，速度最快）
//   3. 全部写入完成后：执行 FTS 重建命令（一次性操作）
//   4. 重建完成后：重新创建三个触发器（用于后续增量同步）
//
// 错误做法（V1.0）：触发器存在时做批量 INSERT，每行触发一次 FTS 写入，
//                   1 万条批量 = 1 万次 FTS 单次写入，完全失去批量优势
// ============================================================

class DatabaseManager {

    func beginBulkInsert() {
        // 步骤 1：删除 FTS 同步触发器，避免每行触发 FTS 写入
        db.execute("DROP TRIGGER IF EXISTS files_ai")
        db.execute("DROP TRIGGER IF EXISTS files_ad")
        db.execute("DROP TRIGGER IF EXISTS files_au")
    }

    func insertBatch(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }
        // 步骤 2：使用事务批量写入 files 主表（此时无触发器，速度纯粹）
        // 使用 INSERT OR IGNORE（非 REPLACE），避免触发隐式 DELETE+INSERT
        try? db.transaction {
            let stmt = try db.prepare("""
                INSERT OR IGNORE INTO files
                    (volume_id, name, parent_path, size, mod_time, create_time, file_ext, is_dir)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
            for r in records {
                try stmt.run(r.volumeId, r.name, r.parentPath,
                             r.size, r.modTime, r.createTime, r.fileExt, r.isDir)
            }
        }
    }

    func endBulkInsert() {
        // 步骤 3：一次性重建整个 FTS 索引（比逐行插入快数十倍）
        db.execute("INSERT INTO files_fts(files_fts) VALUES('rebuild')")

        // 步骤 4：重新创建触发器，用于后续增量更新
        db.execute("""
            CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
                INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
            END
        """)
        db.execute("""
            CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
                INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
            END
        """)
        db.execute("""
            CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE OF name ON files BEGIN
                INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
                INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
            END
        """)
    }
}
```

### 4.3 增量监控（Delta Watcher）

#### 4.3.1 APFS / HFS+ 内置盘——FSEvents（修复 T-02 内存泄漏）

```swift
import CoreServices

class FSEventsWatcher {
    private var streamRef: FSEventStreamRef?

    // ⚠️ 修复 T-02：使用 passUnretained，由调用方持有 FSEventsWatcher 强引用
    // passRetained 会使引用计数永远无法归零，导致内存泄漏
    func startWatching(paths: [String]) {
        let pathsToWatch = paths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),  // ✅ 不增加引用计数
            retain: nil, release: nil, copyDescription: nil
        )

        streamRef = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info!).takeUnretainedValue()
                let paths   = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
                watcher.handleEvents(paths: paths, flags: eventFlags, count: numEvents)
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,    // latency：聚合 1 秒内的事件后批量处理，平衡实时性与 CPU 占用
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |   // 文件级（而非目录级）事件
                kFSEventStreamCreateFlagWatchRoot       // 监控挂载点根路径变化
            )
        )

        FSEventStreamScheduleWithRunLoop(streamRef!,
                                         CFRunLoopGetMain(),
                                         CFRunLoopMode.defaultMode.rawValue as CFString)
        FSEventStreamStart(streamRef!)
    }

    func stopWatching() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    private func handleEvents(paths: [String],
                               flags: UnsafePointer<FSEventStreamEventFlags>,
                               count: Int) {
        var updatePaths:  [String] = []
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

        DispatchQueue.global(qos: .utility).async {
            DatabaseManager.shared.deleteFiles(paths: deletedPaths)
            DatabaseManager.shared.updateFiles(paths: updatePaths)
        }
    }

    deinit { stopWatching() }
}
```

#### 4.3.2 exFAT / NTFS 外接硬盘——目录树 modTime 快照对比

> FSEvents 对 exFAT / NTFS 格式的外接介质覆盖不完整，必须自行实现差异检测。

```swift
class ExternalDriveWatcher {

    /// 外接盘挂载时由 DiskManager 调用
    func onVolumeMounted(mountPath: String, volumeId: String) {
        DispatchQueue.global(qos: .background).async {
            // 1. 从数据库读取上次快照：[parentPath/name → modTime]
            let oldSnapshot = DatabaseManager.shared.getSnapshot(volumeId: volumeId)

            // 2. 遍历当前文件系统，生成新快照
            let newSnapshot = self.buildModTimeSnapshot(mountPath: mountPath)

            // 3. 差异对比
            var toUpsert: [String] = []
            var toDelete: [String] = []

            for (fullPath, modTime) in newSnapshot {
                if oldSnapshot[fullPath] != modTime { toUpsert.append(fullPath) }
            }
            for fullPath in oldSnapshot.keys where newSnapshot[fullPath] == nil {
                toDelete.append(fullPath)
            }

            // 4. 批量同步
            DatabaseManager.shared.deleteFiles(paths: toDelete)
            DatabaseManager.shared.upsertFilesByPath(paths: toUpsert, volumeId: volumeId)
        }
    }

    // 使用 fts 遍历，仅收集 fullPath → modTime，不写入任何数据库
    private func buildModTimeSnapshot(mountPath: String) -> [String: Double] {
        var snapshot: [String: Double] = [:]
        let pathBytes = (mountPath as NSString).utf8String!
        var paths: [UnsafeMutablePointer<CChar>?] = [strdup(pathBytes), nil]
        defer { paths.forEach { free($0) } }

        guard let fts = fts_open(&paths, FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV, nil) else {
            return snapshot
        }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_D else { continue }
            let path    = String(cString: entry.pointee.fts_path)
            let modTime = Double(entry.pointee.fts_statp!.pointee.st_mtimespec.tv_sec)
            snapshot[path] = modTime
        }
        return snapshot
    }
}
```

### 4.4 搜索与过滤引擎

#### 4.4.1 搜索 SQL 构建（修复 T-04 前缀匹配问题）

```swift
struct SearchParams {
    var keyword:     String   = ""
    var extensions:  [String] = []
    var minSize:     Int64?   = nil
    var maxSize:     Int64?   = nil
    var afterDate:   Double?  = nil
    var beforeDate:  Double?  = nil
    var onlyFiles:   Bool     = false
    var onlyFolders: Bool     = false
    var pathContains: String? = nil
    var volumeId:    String?  = nil
}

class QueryBuilder {

    func build(_ params: SearchParams) -> (sql: String, bindings: [DatabaseValueConvertible]) {
        var conditions: [String] = []
        var bindings:   [DatabaseValueConvertible] = []

        // --------------------------------------------------------
        // 关键词搜索：FTS5 前缀匹配（修复 T-04）
        // ⚠️ 使用 "keyword*" 而非 "keyword"，实现前缀匹配
        //    搜"汇报"可命中"季度汇报总结"
        // 多关键词拆分后用 AND 连接，每个词独立前缀匹配
        // --------------------------------------------------------
        if !params.keyword.isEmpty {
            let ftsQuery = params.keyword
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))*\"" }
                .joined(separator: " AND ")
            conditions.append("files.id IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?)")
            bindings.append(ftsQuery)
        }

        // 后缀过滤（参数化，防注入）
        if !params.extensions.isEmpty {
            let ph = params.extensions.map { _ in "?" }.joined(separator: ",")
            conditions.append("files.file_ext IN (\(ph))")
            params.extensions.forEach { bindings.append($0) }
        }

        // 大小过滤
        if let min = params.minSize { conditions.append("files.size > ?"); bindings.append(min) }
        if let max = params.maxSize { conditions.append("files.size < ?"); bindings.append(max) }

        // 时间过滤
        if let after  = params.afterDate  { conditions.append("files.mod_time > ?"); bindings.append(after) }
        if let before = params.beforeDate { conditions.append("files.mod_time < ?"); bindings.append(before) }

        // 类型过滤
        if params.onlyFiles   { conditions.append("files.is_dir = 0") }
        if params.onlyFolders { conditions.append("files.is_dir = 1") }

        // 路径过滤（参数化）
        if let path = params.pathContains {
            conditions.append("files.parent_path LIKE ?")
            bindings.append("%\(path)%")
        }

        // 介质过滤
        if let vid = params.volumeId {
            conditions.append("files.volume_id = ?")
            bindings.append(vid)
        }

        let where_ = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
            SELECT files.id, files.name, files.parent_path,
                   files.size, files.mod_time, files.is_dir
            FROM files
            \(where_)
            ORDER BY files.name ASC
            LIMIT 100000
        """
        return (sql, bindings)
    }
}
```

#### 4.4.2 高级语法解析器（补全 T-03 缺失的 `parseDateRange` 实现）

```swift
// 输入示例："汇报 size:>50MB ext:pdf dm:2026-01-01..2026-03-01"
// 输出：SearchParams { keyword="汇报", minSize=52428800,
//                     extensions=["pdf"], afterDate=..., beforeDate=... }

class SyntaxParser {

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = TimeZone.current
        return f
    }()

    func parse(_ raw: String) -> SearchParams {
        var params = SearchParams()
        var keyParts: [String] = []

        for token in raw.components(separatedBy: .whitespaces) where !token.isEmpty {
            if      token.hasPrefix("ext:")    { params.extensions  = parseExt(token)           }
            else if token.hasPrefix("size:>")  { params.minSize     = parseSize(String(token.dropFirst(6))) }
            else if token.hasPrefix("size:<")  { params.maxSize     = parseSize(String(token.dropFirst(6))) }
            else if token.hasPrefix("size:")   { parseSizeRange(String(token.dropFirst(5)), into: &params) }
            else if token.hasPrefix("dm:")     { parseDateRange(String(token.dropFirst(3)),  into: &params) }
            else if token.hasPrefix("path:")   { params.pathContains = String(token.dropFirst(5)) }
            else if token == "folder:"         { params.onlyFolders  = true }
            else if token == "file:"           { params.onlyFiles    = true }
            else                               { keyParts.append(token) }
        }
        params.keyword = keyParts.joined(separator: " ")
        return params
    }

    // --------------------------------------------------------
    // 修复 T-03：补全 parseDateRange 完整实现
    // 支持格式：
    //   dm:>2026-01-01          （晚于某日）
    //   dm:<2026-03-01          （早于某日）
    //   dm:2026-01-01..2026-03-01（区间）
    // --------------------------------------------------------
    private func parseDateRange(_ s: String, into params: inout SearchParams) {
        if s.hasPrefix(">") {
            params.afterDate  = parseDate(String(s.dropFirst()))
        } else if s.hasPrefix("<") {
            params.beforeDate = parseDate(String(s.dropFirst()))
        } else if s.contains("..") {
            let parts = s.components(separatedBy: "..")
            if parts.count == 2 {
                params.afterDate  = parseDate(parts[0])
                // 结束日期加一天（含当天），精确到秒
                if let end = parseDate(parts[1]) { params.beforeDate = end + 86400 }
            }
        } else {
            // 仅输入日期视为当天：00:00:00 ~ 23:59:59
            if let day = parseDate(s) {
                params.afterDate  = day
                params.beforeDate = day + 86400
            }
        }
    }

    private func parseSizeRange(_ s: String, into params: inout SearchParams) {
        let parts = s.components(separatedBy: "..")
        if parts.count == 2 {
            params.minSize = parseSize(parts[0])
            params.maxSize = parseSize(parts[1])
        }
    }

    private func parseExt(_ token: String) -> [String] {
        token.dropFirst(4)
             .components(separatedBy: ",")
             .map { $0.lowercased().trimmingCharacters(in: .init(charactersIn: " .")) }
             .filter { !$0.isEmpty }
    }

    private func parseDate(_ s: String) -> Double? {
        SyntaxParser.isoFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
                                 .map { $0.timeIntervalSince1970 }
    }

    private func parseSize(_ s: String) -> Int64 {
        let s = s.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Int64)] = [
            ("TB", 1_099_511_627_776), ("GB", 1_073_741_824),
            ("MB", 1_048_576), ("KB", 1_024), ("B", 1)
        ]
        for (suffix, mult) in units {
            if s.hasSuffix(suffix), let n = Double(s.dropLast(suffix.count)) {
                return Int64(n * Double(mult))
            }
        }
        return Int64(s) ?? 0
    }
}
```

### 4.5 权限检测与引导（修复 T-06 FDA 检测兼容性）

```swift
class PermissionManager {

    /// 检测全磁盘访问权限（Full Disk Access）
    ///
    /// 修复 T-06：使用 open() 系统调用而非仅判断 isReadableFile
    /// isReadableFile 在沙盒外可能返回 true 但实际无法读取内容
    /// 通过 errno == EACCES 精确判断权限拒绝场景，兼容 macOS 12~15
    static func hasFDA() -> Bool {
        let tccPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(tccPath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true           // 能打开 = 有 FDA
        }
        return errno != EACCES    // EACCES = 明确无权限；其他错误（文件不存在等）暂视为可能有权限
    }

    /// 引导用户在系统设置中开启 FDA
    static func openFDASystemPreferences() {
        // macOS 13+：System Settings；macOS 12：System Preferences
        // 使用同一个 URL，系统自动路由到正确的设置面板
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 监听权限变更（轮询方案，每 2 秒检测一次，用户完成授权后自动触发索引）
    static func startMonitoringFDA(onChange: @escaping (Bool) -> Void) -> Timer {
        var lastState = hasFDA()
        return Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let current = hasFDA()
            if current != lastState {
                lastState = current
                DispatchQueue.main.async { onChange(current) }
            }
        }
    }
}
```

---

## 五、UI/UX 详细设计规范

### 5.1 设计原则

1. **功能优先、极简高效**：所有元素服务于「快速搜索、快速定位文件」，无多余装饰
2. **1:1 对标 Everything**：操作逻辑、菜单结构、快捷键对标 Windows Everything，降低学习成本
3. **完全适配 macOS 规范**：自动跟随系统浅色/深色模式，使用 macOS 原生语义化颜色

### 5.2 主界面布局（对标 Everything 截图）

```
┌───────────────────────────────────────────────────────────────────────┐
│  ● ● ●  [全部介质▼]  [🔍 搜索文件名或输入搜索语法...    Cmd+F  ] [≡]  │ ← 顶部工具栏
├───────────────────────────────────────────────────────────────────────┤
│  名称 ↑                  │ 路径                    │ 大小   │ 修改时间  │ ← 列头（可点击排序）
├───────────────────────────────────────────────────────────────────────┤
│  📄 **汇**报Q1.pdf        │ /Users/admin/Desktop    │ 2.3 MB │2026/03/01 │
│  📄 **汇**报Q2.xlsx       │ /Volumes/MyDisk/工作    │ 1.1 MB │2026/02/15 │ ← 斑马线
│  📁 季度**汇**报总结       │ /Users/admin/文档       │  —     │2026/01/20 │
│  ··· （虚拟滚动，百万条无卡顿）                                         │
├───────────────────────────────────────────────────────────────────────┤
│  3 个对象                   正在索引：内置硬盘 (78%)...    选中：0 个   │ ← 底部状态栏
└───────────────────────────────────────────────────────────────────────┘
```

### 5.3 各区域详细规范

#### 顶部工具栏

| 元素 | 控件类型 | 规范 |
|------|---------|------|
| 搜索范围下拉 | `NSPopUpButton` | 选项：全部介质 / 内置硬盘 / 各外接介质名称 |
| 搜索输入框 | `NSSearchField` | 占工具栏 80% 宽度；聚焦快捷键 `Cmd+F`；占位符"搜索文件名或输入搜索语法..." |
| 高级过滤按钮 | `NSButton` | 折叠/展开右侧过滤侧边栏 |
| 设置按钮 | `NSButton` | 打开设置窗口 |

#### 结果表格（核心区域）

| 属性 | 规范 |
|------|------|
| 控件 | `NSTableView`（**严禁使用 SwiftUI List**） |
| 数据源 | 实现 `NSTableViewDataSource`，仅向系统提供可见行数据（虚拟滚动） |
| 默认列（顺序固定，与 Everything 一致） | 名称 / 路径 / 大小 / 修改时间 |
| 名称列 | `NSWorkspace.shared.icon(forFile:)` 获取系统图标 + 文件名；关键词高亮用 `NSAttributedString` |
| 路径列 | 显示 `parent_path`（父目录完整路径，不含文件名本身） |
| 大小列 | 右对齐；格式：< 1KB → `xxx B`；< 1MB → `xxx KB`；< 1GB → `xx.x MB`；≥ 1GB → `xx.x GB`；文件夹 → `—` |
| 修改时间列 | 格式 `yyyy/MM/dd HH:mm`，使用本地时区 |
| 斑马线 | `tableView.usesAlternatingRowBackgroundColors = true` |
| 列排序 | 点击列头正反排序；`NSSortDescriptor` 配合数据源排序 |
| 列宽 | 可拖拽调整；列宽存入 `UserDefaults` 持久化 |
| 行高 | 默认 22px；设置中支持 18px（紧凑）/ 26px（舒适） |

#### 底部状态栏

| 位置 | 内容 | 更新时机 |
|------|------|----------|
| 左侧 | `xxx 个对象`（当前过滤后总数，不是索引总数） | 每次搜索结果更新后 |
| 中间 | 索引状态文字，如"正在索引：内置硬盘 (78%)…" / "索引就绪" / "正在监控…" | 索引进度变化时 |
| 右侧 | 未选中：空；单选：完整路径；多选：`已选中 x 个` | 选中行变化时 |

### 5.4 交互规范

#### 键盘快捷键

| 快捷键 | 功能 | 备注 |
|--------|------|------|
| `Cmd+F` | 聚焦搜索框 | 主窗口激活状态下 |
| `双击 Option` | 全局唤出主窗口 | 需辅助功能权限；可在设置中自定义 |
| `Enter` | 用默认程序打开 | |
| `Cmd+Enter` | 在 Finder 中显示 | 最高频操作 |
| `Space` | QuickLook 预览 | |
| `Delete` | 移到废纸篓 | 需二次确认弹窗（可设置跳过） |
| `Cmd+C` | 复制文件 | |
| `Cmd+Shift+C` | 复制完整路径 | |
| `Cmd+A` | 全选当前结果 | |
| `Esc` | 清空搜索框内容 | |
| `↑ / ↓` | 在结果列表中移动焦点 | |

#### 右键菜单结构

```
打开                                   Enter
在访达中显示                           Cmd+Enter
────────────────────────────────────
复制完整路径                           Cmd+Shift+C
复制所在文件夹路径
────────────────────────────────────
复制文件
移到废纸篓                             Delete
────────────────────────────────────
（多选时追加）批量操作 x 个文件 ▶
    移到废纸篓
    复制到...
    移动到...
```

### 5.5 视觉规范

| 属性 | 规范 |
|------|------|
| 英文字体 | SF Pro（系统默认，无需指定） |
| 中文字体 | PingFang SC（系统默认，无需指定） |
| 字号 | 表格行 13pt；搜索框 14pt；状态栏 12pt；列标题 13pt Bold |
| 关键词高亮色 | `NSColor.systemYellow` 背景（浅色/深色模式均可用） |
| 窗口默认尺寸 | 1200 × 700 pt |
| 窗口最小尺寸 | 800 × 500 pt |
| 深浅色适配 | 使用 `NSColor.controlBackgroundColor`、`NSColor.labelColor` 等语义颜色，禁止硬编码 RGB |
| 窗口置顶 | `window.level = .floating`（可选功能，设置中开关） |

---

## 六、安全审查要点（供 CodeX 审查）

### 6.1 沙盒与权限配置

```xml
<!-- QuickSearch.entitlements -->
<!-- App Sandbox 必须完全关闭，沙盒应用无法访问任意路径文件 -->
<!-- ⚠️ com.apple.security.app-sandbox 键不得出现，或显式设置为 <false/> -->

<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Hardened Runtime：启用代码签名保护 -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    <!-- 无沙盒标识 = 沙盒关闭 -->
</dict>
</plist>
```

### 6.2 SQL 注入防护（强制，CodeX 必须逐条核查）

```swift
// ✅ 正确：参数化绑定（所有用户输入路径）
let stmt = try db.prepare("SELECT * FROM files WHERE parent_path LIKE ?")
try stmt.run("%\(userInput)%")

// ✅ 正确：FTS MATCH 使用转义后的参数化查询
let ftsQuery = "\"" + keyword.replacingOccurrences(of: "\"", with: "\"\"") + "*\""
let stmt = try db.prepare("SELECT rowid FROM files_fts WHERE files_fts MATCH ?")
try stmt.run(ftsQuery)

// ❌ 错误：禁止任何形式的 SQL 字符串拼接
let sql = "SELECT * FROM files WHERE name LIKE '%\(userInput)%'"   // 注入风险！
```

### 6.3 资源消耗限制

```swift
// ✅ 扫描与监控线程必须使用低 QoS
DispatchQueue.global(qos: .utility)      // 扫描线程（推荐）
DispatchQueue.global(qos: .background)   // 外接盘对比（更低优先级）
// ❌ 禁止用于长耗时后台任务
DispatchQueue.global(qos: .userInitiated)

// ✅ 内存水位控制：每 kBatchSize 条立即 flush
if batch.count >= kBatchSize { DatabaseManager.shared.insertBatch(batch); batch.removeAll(...) }
```

### 6.4 文件系统遍历边界控制

```swift
// ✅ 必须同时设置以下三个 fts 标志，任何一项缺失都会引发安全问题
let flags = FTS_NOCHDIR    // 防止工作目录被修改，保证多线程安全
          | FTS_PHYSICAL   // 不跟随符号链接，防止无限递归循环
          | FTS_XDEV       // 不跨越文件系统边界，防止扫描到网络挂载点
```

### 6.5 FSEvents 内存管理

```swift
// ✅ 正确：passUnretained，不增加引用计数（调用方持有强引用）
info: Unmanaged.passUnretained(self).toOpaque()

// ❌ 错误：passRetained 导致永久内存泄漏（V1.0 的问题）
info: Unmanaged.passRetained(self).toOpaque()
```

---

## 七、开发里程碑

| 阶段 | 周期 | 核心目标 | 核心交付物 | 量化验收标准 |
|------|------|----------|------------|-------------|
| **M1 引擎地基** | 2 周 | 数据库设计 + 文件遍历 | SQLite Schema；fts 遍历模块；批量写入模块（含 FTS 重建流程） | 遍历 1TB 内置盘并存入 SQLite ≤ 3 分钟；无崩溃、无数据丢失 |
| **M2 实时监控** | 1.5 周 | FSEvents + 外接盘适配 | FSEventsWatcher；ExternalDriveWatcher；DiskManager | 内置盘文件变更 ≤ 1s 同步；外接 U 盘插入自动识别并触发索引 |
| **M3 极限 UI** | 1.5 周 | 渲染百万条数据 | AppKit 主界面；虚拟化 NSTableView；搜索防抖；关键词高亮 | 100 万条数据快速滚动无掉帧；输入关键词 ≤ 100ms 出结果 |
| **M4 搜索增强** | 1 周 | 过滤语法 + 多介质 | SyntaxParser；QueryBuilder；多介质切换 UI | 支持全部 P0 语法；组合过滤 ≤ 200ms；多介质并行搜索结果合并正确 |
| **M5 体验打磨** | 1 周 | 权限引导 + 交互完善 | FDA 引导流程；完整右键菜单；键盘快捷键；状态栏 | FDA 授权后无需重启自动触发索引；所有快捷键生效；双击/空格行为与 Finder 一致 |

**合计：7 周（MVP/P0 全量）**

---

## 八、风险与应对措施

| 风险 | 描述 | 应对措施 |
|------|------|----------|
| **FDA 权限获取困难** | 用户不了解系统权限设置，无法自行完成授权 | 图文引导 + 一键跳转；无权限目录静默跳过并记录日志，不阻塞主流程 |
| **2TB HDD 索引超时** | HDD 随机 IO 特性导致索引耗时远超 SSD | 针对 HDD 优化顺序读取；提供节能/极速模式切换；显示剩余时间估算安抚用户 |
| **exFAT 外接盘增量不准** | FSEvents 对 exFAT/NTFS 覆盖不完整，文件变更可能漏检 | 外接盘挂载时全量 modTime 快照对比；每 30 分钟定期触发一次校验 |
| **FTS5 中文子词匹配** | unicode61 按 Unicode 字符分割，"汇报"无法直接命中"月度汇报总结"中的子词 | P0 阶段：FTS 前缀匹配 + LIKE 兜底；P1 阶段：集成 jieba 或自定义分词器 |
| **macOS API 版本变化** | TCC 权限 API、FSEvents 行为在新版 macOS 可能调整 | 使用系统公开稳定 API，避免私有 API；做版本判断，beta 版本提前适配 |
| **索引一致性** | 高频变更、外接存储反复插拔导致索引与实际文件不一致 | 提供手动重建索引入口；介质挂载时自动增量校验；SQLite WAL 保证写入原子性 |

---

## 附录一：项目文件结构参考

```
QuickSearch/
├── App/
│   ├── AppDelegate.swift              # 应用入口，权限检测，菜单栏图标
│   └── MainWindowController.swift     # 主窗口生命周期管理
├── UI/
│   ├── MainViewController.swift       # 主界面：搜索框 + 表格 + 状态栏
│   ├── ResultTableView.swift          # 虚拟化 NSTableView 数据源与代理
│   ├── SearchBarView.swift            # 搜索输入框（含 50ms 防抖）
│   ├── StatusBarView.swift            # 底部状态栏（对象数 / 索引状态 / 选中信息）
│   └── PermissionGuideWindow.swift    # FDA 权限引导窗口
├── Engine/
│   ├── FileSystemScanner.swift        # BSD fts 底层遍历引擎
│   ├── FSEventsWatcher.swift          # FSEvents 文件系统监控（APFS/HFS+）
│   ├── ExternalDriveWatcher.swift     # modTime 快照对比（exFAT/NTFS）
│   └── DiskManager.swift             # DiskArbitration 介质挂载/卸载管理
├── Database/
│   ├── DatabaseManager.swift          # SQLite 连接管理、PRAGMA 配置
│   ├── SchemaManager.swift            # 建表、建索引、触发器管理
│   └── BulkInserter.swift            # 全量构建批量写入（含 FTS rebuild 流程）
├── Search/
│   ├── SearchEngine.swift             # 搜索主入口，协调 FTS + 过滤
│   ├── SyntaxParser.swift             # 高级搜索语法解析器
│   └── QueryBuilder.swift            # SearchParams → SQL + Bindings
├── Model/
│   ├── FileRecord.swift               # 文件元数据值类型
│   ├── VolumeInfo.swift               # 存储介质信息
│   └── SearchParams.swift             # 搜索参数聚合结构体
├── Utilities/
│   ├── PermissionManager.swift        # FDA 权限检测与监听
│   ├── LogManager.swift               # 分级日志（info/warn/error）
│   └── SizeFormatter.swift           # 文件大小友好格式化
└── Resources/
    ├── QuickSearch.entitlements        # 无沙盒配置
    └── Assets.xcassets
```

---

## 附录二：高级搜索语法规范（对标 Everything）

| 语法 | 说明 | 示例 |
|------|------|------|
| `ext:xxx` | 按后缀过滤（支持逗号分隔多个） | `ext:pdf` / `ext:zip,rar,7z` |
| `size:>xxx` | 文件大于指定大小 | `size:>50MB` |
| `size:<xxx` | 文件小于指定大小 | `size:<1GB` |
| `size:x..y` | 文件大小在区间内 | `size:1MB..100MB` |
| `dm:>yyyy-MM-dd` | 修改时间晚于指定日期 | `dm:>2026-01-01` |
| `dm:<yyyy-MM-dd` | 修改时间早于指定日期 | `dm:<2026-03-01` |
| `dm:x..y` | 修改时间在区间内 | `dm:2026-01-01..2026-03-01` |
| `dm:yyyy-MM-dd` | 仅限该天 | `dm:2026-03-08` |
| `path:xxx` | 路径包含指定字符串 | `path:Desktop` / `path:~/工作` |
| `folder:` | 仅搜索文件夹 | `folder: 项目` |
| `file:` | 仅搜索文件 | `file: 报告` |
| `*` | 通配符，匹配任意字符 | `*.mp4` |
| `?` | 通配符，匹配单个字符 | `0?.zip` |

**组合示例**
- `汇报 size:>50MB ext:pdf` → 文件名含"汇报"、大于 50MB 的 PDF
- `dm:2026-01-01..2026-03-01 folder:` → 2026 年 Q1 修改的所有文件夹
- `会议 ext:mp4,mov size:>500MB` → 大视频会议录像文件

---

## 附录三：术语说明

| 术语 | 说明 |
|------|------|
| FSEvents | macOS 原生文件系统事件监控框架（CoreServices），等效于 Windows USN 日志 |
| FTS5 | SQLite 内置全文搜索扩展，实现倒排索引，毫秒级文件名检索 |
| fts / dirent | POSIX 标准文件系统遍历 C API（非 Swift FileManager），直接操作内核 VFS |
| DiskArbitration | macOS 原生磁盘管理框架，实时监控介质挂载/卸载/弹出事件 |
| WAL | SQLite Write-Ahead Logging 模式，写入不阻塞读取，并发性能大幅提升 |
| FDA | Full Disk Access（全磁盘访问），macOS 最高级别文件读取权限 |
| UTI | Uniform Type Identifier，macOS 统一文件类型标识符（比后缀名更精准，P1 可选） |
| XPC | macOS 原生进程间通信框架（P1 阶段用于拆分后台索引进程） |
| QoS | Quality of Service，GCD 线程优先级；索引任务必须使用 `.utility` 或 `.background` |

---

*文档版本：V1.1*
*编制日期：2026-03-08*
*设计理念：天下武功，唯快不破。克制做加法，专注把"搜文件名"做到极致。*
