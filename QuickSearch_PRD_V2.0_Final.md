# QuickSearch for Mac 产品需求与技术实现蓝图（Final）

**文档版本**：V2.0 Final  
**编制日期**：2026-03-08  
**文档状态**：Ready for Development  
**适用对象**：  
- **Gemini**：需求合规性与范围把控  
- **ClaudeCode**：架构落地与核心代码实现  
- **CodeX**：安全、性能、规范审查

---

## 1. 项目背景与目标

### 1.1 背景与核心痛点
Mac 原生 Finder/Spotlight 在重度文件检索场景存在以下问题：

1. 文件名搜索不纯粹，混入文件内容/邮件等结果，噪声高。  
2. 同名文件检索结果缺少完整路径列，定位成本高。  
3. 2TB 级内置盘或外接盘索引构建慢甚至失败，导致无法稳定搜索。  
4. 外接存储（exFAT/NTFS）实时更新不可靠，结果一致性差。  

### 1.2 产品目标（P0）

1. 对 macOS 本地盘与外接盘提供高性能、纯文件名优先搜索。  
2. 默认结果表格固定展示：`名称`、`路径`、`大小`、`修改时间`。  
3. 支持按文件夹、文件名、文件类型、文件大小、修改时间组合过滤。  
4. 百万级索引下保持毫秒级查询响应与流畅滚动体验。  
5. 不依赖 Spotlight，构建独立索引引擎，保证可控性能与一致性。  

### 1.3 非目标（本期不做）

1. 文件内容全文索引（OCR、Office/PDF 内容检索）。  
2. 云同步索引。  
3. Mac App Store 沙盒上架方案（本期采用非沙盒桌面分发）。  

---

## 2. 目标用户与场景

### 2.1 目标用户

1. Windows Everything 迁移用户。  
2. 大容量文件管理用户（设计、视频、开发、财务资料管理）。  
3. 频繁使用外接硬盘/U 盘/移动 SSD 的用户。  

### 2.2 关键使用场景

1. 在 1 秒内定位指定文件并打开或在 Finder 中显示。  
2. 在多个介质同时检索，快速筛出某后缀/大小/时间区间文件。  
3. 外接盘重新挂载后快速恢复可搜索状态。  

---

## 3. 功能需求（按优先级）

### 3.1 P0 核心搜索

| 编号 | 需求 | 说明 | 验收标准 |
|---|---|---|---|
| FR-001 | 实时搜索 | 输入后自动检索，无需回车 | 防抖 50ms；输入后 100ms 内返回首屏结果 |
| FR-002 | 文件名优先匹配 | 默认仅对文件/文件夹名称检索 | 不检索文件内容与邮件等外部数据源 |
| FR-003 | 搜索对象切换 | 全部/仅文件/仅文件夹 | 切换后实时更新结果 |
| FR-004 | 搜索范围限定 | 指定根目录或介质范围 | 支持“全部介质/内置盘/指定外接盘/自定义路径” |
| FR-005 | 多关键词 | 空格分词，默认 AND 语义 | `季度 报告` 等价于同时命中两个词 |

### 3.2 P0 高级过滤与语法

| 编号 | 需求 | 说明 | 验收标准 |
|---|---|---|---|
| FR-006 | 类型过滤 | 按扩展名过滤 | 支持 `ext:pdf`、`ext:zip,rar,7z` |
| FR-007 | 大小过滤 | 按阈值或区间过滤 | 支持 `size:>50MB`、`size:1MB..1GB` |
| FR-008 | 时间过滤 | 按修改时间过滤 | 支持 `dm:>2026-01-01`、`dm:2026-01-01..2026-03-01` |
| FR-009 | 路径过滤 | 按父路径关键字过滤 | 支持 `path:Desktop` |
| FR-010 | 对象语法 | 文件/文件夹语法开关 | 支持 `file:`、`folder:` |
| FR-011 | 通配符 | 文件名通配符 | 支持 `*`、`?`，与语法解析器一致实现 |

### 3.3 P0 索引构建与增量更新

| 编号 | 需求 | 说明 | 验收标准 |
|---|---|---|---|
| FR-012 | 首次全量索引 | 扫描并写入本地 SQLite | 2TB SSD ≤ 5 分钟；2TB HDD ≤ 15 分钟 |
| FR-013 | 增量更新（内置盘） | FSEvents 监听 APFS/HFS+ | 文件变更后 1.5 秒内可检索 |
| FR-014 | 增量更新（外接盘） | exFAT/NTFS 挂载时差异校验 | 挂载后自动执行并更新索引 |
| FR-015 | 索引生命周期 | 支持暂停/继续/取消/重建 | UI 可见状态与进度，异常可恢复 |
| FR-016 | 排除规则 | 系统目录/自定义目录排除 | 支持规则启停并持久化 |

### 3.4 P0 结果展示与操作（对标 Everything）

| 编号 | 需求 | 说明 | 验收标准 |
|---|---|---|---|
| FR-017 | 表格展示 | AppKit `NSTableView` | 默认列顺序固定：名称/路径/大小/修改时间 |
| FR-018 | 列交互 | 列宽拖拽、列头排序 | 支持升降序，列宽持久化 |
| FR-019 | 高亮命中 | 名称列命中片段高亮 | 高亮颜色适配深浅色模式 |
| FR-020 | 快捷操作 | 打开、显示于 Finder、QuickLook | 双击打开；`Cmd+Enter`；`Space` |
| FR-021 | 右键菜单 | 常用文件操作 | 打开、显示、复制路径、移到废纸篓等 |
| FR-022 | 状态栏 | 显示对象数和索引状态 | 左侧对象数，中间索引状态，右侧选中信息 |

### 3.5 P1/P2

1. P1：搜索历史、书签、快捷键自定义、XPC 后台进程拆分。  
2. P2：索引加密（含密钥管理）、自动更新。  

---

## 4. 非功能需求（强制）

### 4.1 性能 SLO

1. 单关键词查询 P95 ≤ 100ms（百万级索引）。  
2. 组合过滤查询 P95 ≤ 200ms。  
3. UI 首屏渲染 ≤ 16ms 帧预算，不出现持续掉帧。  
4. 后台空闲 CPU ≤ 1%，内存 ≤ 100MB。  
5. 索引构建峰值 CPU ≤ 30%，内存 ≤ 300MB。  

### 4.2 稳定性

1. 连续 7×24 小时运行无崩溃、无索引损坏。  
2. 异常断电/崩溃后可基于 SQLite WAL 自动恢复。  
3. 外接盘中途卸载、权限不足、磁盘满等场景不崩溃。  

### 4.3 兼容性

1. 最低系统：macOS 12.0。  
2. 芯片：Apple Silicon + Intel Universal Binary。  
3. 文件系统：APFS、HFS+、exFAT、FAT32、NTFS（只读或系统可写挂载）。  

### 4.4 安全与隐私

1. 索引数据仅本地保存，不上传云端。  
2. 全部查询使用参数化绑定，禁止 SQL 拼接。  
3. 默认日志不记录敏感文件内容，只记录路径和错误码级别信息。  

---

## 5. 技术架构与实现路径

### 5.1 架构原则

1. MVP 采用单进程分层架构，优先保证可实现与可调试。  
2. 主数据列表必须 AppKit，不在主列表使用 SwiftUI。  
3. 索引与查询解耦，扫描写入与 UI 渲染线程隔离。  

### 5.2 分层架构

1. UI 层：`NSWindow` + `NSSearchField` + `NSTableView` + 状态栏。  
2. 业务层：`SearchEngine`、`SyntaxParser`、`FilterService`。  
3. 索引层：扫描器、增量监听、批量写入器、查询执行器。  
4. 系统层：FSEvents、DiskArbitration、QuickLook、Permission 管理。  

---

## 6. 数据库设计（SQLite + FTS5）

### 6.1 设计原则

1. 业务主键必须稳定，避免重复数据与冲突歧义。  
2. 全量构建阶段避免逐行 FTS 触发器开销。  
3. 查询采用分页，禁止固定硬截断。  

### 6.2 Schema（最终版）

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA cache_size = -65536;

CREATE TABLE IF NOT EXISTS files (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    volume_uuid   TEXT    NOT NULL,              -- 稳定卷标识（非 /dev/diskXsY）
    full_path     TEXT    NOT NULL,              -- 规范化后的绝对路径
    parent_path   TEXT    NOT NULL,
    name          TEXT    NOT NULL,
    file_ext      TEXT    DEFAULT '',
    size          INTEGER DEFAULT 0,
    mod_time_ns   INTEGER NOT NULL,              -- 纳秒级时间戳，降低同秒碰撞
    create_time   REAL    DEFAULT 0,
    is_dir        INTEGER DEFAULT 0,
    inode         INTEGER DEFAULT 0,
    updated_at    REAL    NOT NULL,
    UNIQUE(volume_uuid, full_path)
);

CREATE INDEX IF NOT EXISTS idx_files_parent     ON files(parent_path);
CREATE INDEX IF NOT EXISTS idx_files_ext        ON files(file_ext);
CREATE INDEX IF NOT EXISTS idx_files_size       ON files(size);
CREATE INDEX IF NOT EXISTS idx_files_mod_ns     ON files(mod_time_ns);
CREATE INDEX IF NOT EXISTS idx_files_is_dir     ON files(is_dir);

CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
    name,
    content='files',
    content_rowid='id',
    tokenize='unicode61 remove_diacritics 2'
);

CREATE TABLE IF NOT EXISTS volumes (
    volume_uuid   TEXT PRIMARY KEY,
    volume_name   TEXT NOT NULL,
    mount_path    TEXT NOT NULL,
    fs_type       TEXT NOT NULL,
    total_size    INTEGER DEFAULT 0,
    is_external   INTEGER DEFAULT 0,
    index_policy  TEXT    DEFAULT 'auto',
    last_scan_at  REAL    DEFAULT 0
);

CREATE TABLE IF NOT EXISTS exclude_rules (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_type     TEXT NOT NULL,                 -- path/ext/name
    pattern       TEXT NOT NULL,
    is_enabled    INTEGER DEFAULT 1
);
```

### 6.3 写入策略

1. 全量构建：暂时移除 FTS 触发器，仅批量写 `files`，结束后执行 `files_fts rebuild`。  
2. 增量更新：使用 `INSERT ... ON CONFLICT(volume_uuid, full_path) DO UPDATE`。  
3. 批大小：`10,000` 条 flush，一次事务提交。  

---

## 7. 索引引擎实现

### 7.1 全量扫描

1. 使用 `fts_open/fts_read + stat`，不使用 `FileManager.enumerator`。  
2. 遍历标志必须包含：`FTS_NOCHDIR | FTS_PHYSICAL | FTS_XDEV`。  
3. 每个 volume 独立任务并发，QoS 使用 `.utility`。  
4. 文件元数据落批处理队列，达到内存水位即 flush。  

### 7.2 增量更新（内置盘）

1. APFS/HFS+ 使用 FSEvents 文件级事件。  
2. FSEventStream 运行在独立后台 RunLoop，避免主线程抖动。  
3. 事件聚合窗口 1.0s，去重后批量更新数据库。  

### 7.3 增量更新（外接盘）

1. 触发时机：DiskArbitration 检测挂载事件。  
2. 算法：流式快照对比，不在内存构建全量 `Dictionary`。  
3. 实现：扫描结果先落临时表 `tmp_snapshot`，再用 SQL 做 `upsert/delete diff`。  
4. 比对键：`full_path + mod_time_ns + size + is_dir`，避免仅用秒级 mtime 漏检。  

---

## 8. 查询与语法引擎

### 8.1 语法规范（P0）

1. `ext:pdf`、`ext:zip,rar`  
2. `size:>50MB`、`size:1MB..1GB`  
3. `dm:>2026-01-01`、`dm:2026-01-01..2026-03-01`  
4. `path:Desktop`  
5. `file:`、`folder:`  
6. `*`、`?` 通配符  

### 8.2 解析规则

1. 支持引号：`path:"/Users/me/My Work"`。  
2. 多关键词默认 AND。  
3. FTS 查询词统一转义后参数绑定。  

### 8.3 查询执行

1. 关键词优先走 `files_fts MATCH`。  
2. 过滤条件走主表索引列。  
3. 分页返回：`LIMIT ? OFFSET ?`，并单独返回总数 `COUNT(*)`。  
4. 排序字段白名单：`name/size/mod_time/path`，禁止用户自由拼接排序列。  

### 8.4 中文检索策略说明

1. P0：采用 unicode61 + 前缀匹配，保障稳定性与性能。  
2. P0 风险：中文子词命中能力有限。  
3. 兜底策略：可选 `LIKE` 仅对小结果集二次过滤，不作为默认全局路径。  
4. P1：引入 CJK 分词器（如 jieba 自定义 tokenizer）提升中文命中质量。  

---

## 9. UI/UX 设计规范（对标 Everything）

### 9.1 窗口布局

1. 顶部：红黄绿窗口按钮 + 搜索输入框 + 范围选择。  
2. 中部：结果表格（四列默认顺序固定）。  
3. 底部：对象数、索引状态、当前选中信息。  

### 9.2 表格列规范

| 列名 | 内容 | 规则 |
|---|---|---|
| 名称 | 图标 + 文件名 | 命中词高亮 |
| 路径 | 父目录完整路径 | 默认显示，不可默认隐藏 |
| 大小 | 文件大小 | 文件夹显示 `—` |
| 修改时间 | 本地时间 | `yyyy/MM/dd HH:mm` |

### 9.3 交互规范

1. 双击：默认应用打开。  
2. `Cmd+Enter`：Reveal in Finder。  
3. `Space`：QuickLook。  
4. 右键菜单：打开、在访达中显示、复制完整路径、复制文件、移到废纸篓。  
5. 列头点击排序，列宽拖拽，列配置持久化。  

### 9.4 视觉规范

1. 字体：SF Pro / PingFang SC。  
2. 支持浅色与深色模式。  
3. 使用语义颜色，避免硬编码 RGB。  
4. 默认窗口尺寸 1200×700，最小 800×500。  

---

## 10. 权限与安全规范（CodeX 审查清单）

### 10.1 权限与分发

1. App Sandbox 关闭（非 MAS 分发）。  
2. 首次启动检测 Full Disk Access（FDA），未授权则弹窗引导。  
3. 跳转系统设置：`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`。  

### 10.2 FDA 检测策略

1. 通过受保护路径实际读访问校验，不以单一路径存在性误判授权状态。  
2. `open()` 成功视为通过；失败视为未确认授权，继续引导并重试。  
3. 授权状态变更后自动触发索引初始化。  

### 10.3 SQL 注入防护

1. 所有 `WHERE` 参数与 `MATCH` 查询必须使用绑定参数。  
2. 排序字段走白名单映射，不接受用户输入原样拼接。  
3. 通配符转 SQL 时统一做转义（`%`、`_`、`\`）。  

### 10.4 资源治理

1. 扫描/对比任务仅 `.utility` 或 `.background`。  
2. 批量写入内存水位控制：10k 条强制 flush。  
3. 监控指标：CPU、内存、事务耗时、FSEvents backlog。  

---

## 11. 测试与验收标准

### 11.1 功能验收

1. P0 需求项 FR-001 至 FR-022 全部通过。  
2. 外接盘挂载/卸载/重挂载全流程可用。  
3. 结果默认显示路径列且可正确区分同名文件。  

### 11.2 性能验收

1. 数据集：100 万、500 万、1000 万文件三档。  
2. 环境：SSD 与 HDD 分开测。  
3. 输出：P50/P95/P99 查询延迟、索引总耗时、峰值资源占用。  

### 11.3 稳定性验收

1. 7×24 小时长稳测试。  
2. 异常注入：权限缺失、磁盘满、拔盘、进程重启。  
3. 一致性校验：随机抽样比对文件系统与索引结果。  

---

## 12. 项目里程碑（建议）

| 里程碑 | 周期 | 交付物 | 退出标准 |
|---|---|---|---|
| M1 引擎地基 | 2 周 | Schema、扫描器、批量写入 | 1TB 内置盘稳定入库 |
| M2 增量监控 | 1.5 周 | FSEvents + 外接盘差异对比 | 变更 1.5 秒内可检索 |
| M3 查询与语法 | 1 周 | Parser + QueryBuilder + 分页 | 语法与过滤通过测试 |
| M4 UI 主界面 | 1.5 周 | AppKit 表格与交互 | 百万级滚动流畅 |
| M5 权限与打磨 | 1 周 | FDA 引导、右键菜单、状态栏 | P0 功能全通过 |
| M6 联调验收 | 1 周 | 性能报告、稳定性报告 | 满足 SLO 并可发布 |

总计：8 周（MVP/P0）。

---

## 13. 风险与应对

| 风险 | 描述 | 应对 |
|---|---|---|
| 权限风险 | 用户未开启 FDA 导致扫描不完整 | 强引导 + 状态可视化 + 重试机制 |
| 外接盘一致性风险 | exFAT/NTFS 无可靠实时事件 | 挂载时流式差异校验 + 定时抽检 |
| 中文命中体验风险 | 默认 tokenizer 对中文子词能力有限 | P0 明确边界，P1 引入 CJK tokenizer |
| 性能回退风险 | 触发器/分页/SQL 回归影响性能 | 基准测试门禁 + 查询计划审计 |
| 复杂度风险 | 过早引入多进程导致交付失控 | P0 单进程，P1 再拆 XPC |

---

## 14. 交付产物清单

1. PRD Final 文档（本文件）。  
2. 技术设计说明（模块接口、时序图、关键 SQL）。  
3. 测试计划与性能基准脚本。  
4. 验收报告模板（功能、性能、稳定性）。  

---

**版本结论**：本版可直接作为 Gemini 审核、ClaudeCode 开发、CodeX 审查的统一基线文档。  
