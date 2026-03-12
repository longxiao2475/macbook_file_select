# QuickSearch M1 索引构建性能优化方案

**版本**: 6.0
**日期**: 2026-03-11
**状态**: 执行中 — Gate-1 已通过，Gate-3 待测
**刚性目标**: NTFS 4TB HDD（1.36TB 已用，约 1,837,622 文件）全量索引 **≤ 700s**

---

## 1. 实测结果汇总（按版本）

### 1.1 优化历史

| 版本 | 策略 | 文件数 | 耗时 | 吞吐 | 关键变化 |
|---|---|---|---|---|---|
| Baseline | BSDScanner 全量扫描 | 1,837,622 | 1704s | ~1079/s | — |
| v1 | + NTFS 系统目录排除 | 1,597,619 | 2086s | ~766/s | 修复重复扫描回归（负优化） |
| v2 | + Priority-only + 缓存目录排除 | 581,329 | 1427s | ~407/s | 过滤非优先扩展名 + 跳过构建/缓存目录 |
| v3 | + InodeSortedScanner + inode 排序 | 565,944 | 1318s | ~429/s | opendir/readdir + inode 排序减少 HDD seek |
| v4 | + Fast-scan (--fast-scan) | ~565k | **待测** | — | 跳过 DT_REG 的 lstat，预期 ≤ 500s |

Gate-1（≤1400s）：**已通过**（v3 = 1318s）
Gate-2（≤1100s）：未通过
Gate-3（≤700s）：**v4 fast-scan 待验证**

---

## 2. 根因分析（已确认）

### 2.1 瓶颈确认：fskit IPC 开销，非磁盘 seek

- CPU 数据：user=5s, sys=31s, wall=1318s → **97% 时间在等待**
- 等待根源：macOS 对 NTFS 采用 fskit 用户态驱动，每次 `lstat()` 调用 = 跨进程 RPC 到 fskit 守护进程
- inode 排序只能减少 seek 距离，无法减少 IPC 调用次数，故仅取得 7.6% 改善（非预期 30-50%）

### 2.2 核心结论

| 问题 | 结论 |
|---|---|
| SQLite 写入瓶颈？ | 否。DB 写入 ≈ 1.7s / 2086s = 0.08%，可忽略 |
| HDD seek 瓶颈？ | 次要。inode 排序减少 seek，但收益有限（7.6%） |
| **真正瓶颈** | **fskit NTFS 驱动 IPC：每次 `lstat()` = 一次进程间 RPC** |
| 突破方向 | 减少 `lstat()` 调用总次数，而非优化单次调用 |

---

## 3. 当前技术方案（已落地）

### 3.1 Priority-only 模式（--priority-only）

**原理**：只索引常用扩展名（文档/压缩包/图片/视频/音频），同时跳过大型无意义目录。

**优先索引的扩展名**（~80 种）：
- 文档：pdf, doc, docx, xls, xlsx, ppt, pptx, odt, txt, md, rtf, pages, numbers, key, epub, etc.
- 压缩包：zip, rar, 7z, tar, gz, bz2, xz, iso, dmg, pkg, deb, rpm, apk, ipa, etc.
- 图片：jpg, jpeg, png, gif, bmp, tiff, heic, heif, webp, svg, psd, ai, raw, cr2, cr3, nef, etc.
- 视频：mp4, mkv, avi, mov, wmv, flv, m4v, ts, rmvb, webm, 3gp, rm, etc.
- 音频：mp3, aac, flac, wav, m4a, ogg, wma, aiff, ape, opus, etc.
- 其他：exe, msi, torrent, db, sqlite, ttf, otf, sketch, fig, xd, djvu, srt, etc.

**内置排除目录**（缓存/构建/版本控制）：
- 前端：node_modules, .npm, .yarn, .pnpm-store
- Python：__pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .tox, venv, .venv
- Java/Android：.gradle, .m2
- Apple：DerivedData
- Rust：.cargo
- 通用缓存：.cache
- 版本控制：.git, .svn, .hg, .bzr
- 系统：.Trash, .Trashes, .Spotlight-V100, .MobileBackups, Thumbs

**效果**：文件数从 1,837,622 → 565,944（-69.2%），耗时 2086s → 1318s（-36.8%）

### 3.2 InodeSortedScanner（NTFS HDD 专用）

**原理**：用 opendir/readdir 收集目录项，按 inode 排序（≈ MFT record 地址顺序），再批量 lstat。

**激活条件**：`isExternal && fsType=ntfs`（自动检测）

**效果**：1427s → 1318s（-7.6%），收益小于预期，因真正瓶颈是 IPC 次数而非 seek 距离

### 3.3 Fast-scan 模式（--fast-scan，核心突破）

**原理**：`readdir()` 返回的 `d_type` 字段对 NTFS 文件有效（fskit 从目录 INDEX_ENTRY 读取，无需额外 I/O）。
- `DT_REG` → 直接跳过 `lstat()`，以 size=0, mtime=0（哨兵值）记录文件
- `DT_DIR` → 仍需 lstat 做 XDEV 边界检测
- `DT_UNKNOWN` → 自动回退到 lstat
- `DT_LNK` → 跳过（符号链接不索引）

**预期效果**：lstat 调用从 ~1.1M → ~110k（仅目录），减少 90% IPC 调用 → 预计 200–500s

**诊断输出**（扫描结束后自动打印）：
```
lstat skipped  : 1,032,847 / 1,143,000 (90.4%)  ← NTFS d_type coverage
```
- 若 fastPathRatio < 0.5，程序自动警告并建议不使用 --fast-scan

**代价**：fast-scan 记录的 size/mtime 为 0，需后续 `--supplement` 补填

### 3.4 Supplement 补录策略（--supplement）

**流程**：
1. 首次全量：`--priority-only --fast-scan` → 快速建立可搜索索引（文件名/路径可用）
2. 后台补录：`--supplement` → 仅 lstat 已索引文件，填补 size/mtime，不重扫

**好处**：用户可在补录期间已经开始搜索，只是大小/时间暂时显示为 0

### 3.5 用户自定义排除（--exclude-dir）

可重复追加额外排除目录名（全局，不分路径层级）：
```bash
QuickSearch /Volumes/LX --priority-only --exclude-dir Backup --exclude-dir old
```

---

## 4. 推荐执行命令

### 4.1 快速首次索引（推荐）

```bash
# 第一步：快速建立可搜索索引（预计 <500s）
time QuickSearch /Volumes/LX \
  --db ~/.local/share/QuickSearch/lx.db \
  --priority-only --fast-scan

# 第二步：后台补充 size/mtime（可在第一步完成后立即在后台运行）
QuickSearch /Volumes/LX \
  --db ~/.local/share/QuickSearch/lx.db \
  --supplement &
```

### 4.2 全量索引（含所有文件类型）

```bash
time QuickSearch /Volumes/LX \
  --db ~/.local/share/QuickSearch/lx.db
```

### 4.3 仅优先文件，不用 fast-scan（完整元数据）

```bash
time QuickSearch /Volumes/LX \
  --db ~/.local/share/QuickSearch/lx.db \
  --priority-only
```

---

## 5. Gate 状态

| Gate | 目标 | 方案 | 状态 |
|---|---|---|---|
| Gate-1 | ≤1400s 全量扫描 | NTFS 系统目录排除 + inode 排序 | ✅ 通过（1318s） |
| Gate-2 | ≤1100s | InodeSortedScanner | ❌ 未通过（1318s > 1100s） |
| Gate-3 | ≤700s priority-only+fast-scan | Fast-scan 跳过 DT_REG lstat | ⏳ 待测（预期 200–500s） |

---

## 6. 验证命令（Gate-3 测试）

```bash
# 清空旧索引，冷测
rm -f /tmp/qs-lx-v4.db

time QuickSearch /Volumes/LX \
  --db /tmp/qs-lx-v4.db \
  --priority-only \
  --fast-scan

# 观察输出中：
# lstat skipped  : X / Y (Z%)  ← 若 Z ≥ 80%，fast-scan 有效
# 若 Z < 50%，说明 NTFS 驱动返回大量 DT_UNKNOWN，fast-scan 效果受限
```

---

## 7. 后续计划

| 步骤 | 内容 | 状态 |
|---|---|---|
| Gate-3 验证 | 运行 v4 fast-scan，确认是否 ≤700s | ⏳ 用户待执行 |
| M2 增量监控 | FSEvents + DiskArbitration 外接盘差异校验 | 待开发 |
| M3 查询引擎 | 语法解析器 + QueryBuilder + 分页 | 待开发 |
| M4 UI 主界面 | AppKit NSTableView | 待开发 |

---

## 8. 回滚策略

1. `--fast-scan` 为显式 opt-in 参数，默认不启用
2. fast-scan 自动回退：DT_UNKNOWN 条目仍走 lstat（无需人工干预）
3. `--supplement` 可随时补全 fast-scan 留下的 0 值，不影响索引完整性
4. InodeSortedScanner 仅在 `isExternal && fsType=ntfs` 时激活，其他磁盘类型保持 BSDScanner
