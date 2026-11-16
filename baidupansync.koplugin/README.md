# BaiduPanSync（KOReader 插件）

按《BaiduPanSync_技术方案.md》V1.4 的阶段 A 实现：**只在本地验证 EPUB 阅读位置的读取、导出、导入、跳转校验和撤销**，不连接任何远端后端，不计算完整 SHA-256 书籍身份。

- 插件版本：0.1.0（阶段 A）
- 目标运行时：KOReader（LuaJIT）；已在本地 KOReader 检出 `c3e5f750b`（2026-11-10）的 macOS 模拟器环境验证
- 阶段范围：方案第 9 节阶段 A；阶段 B（完整 SHA-256 身份、同步引擎）尚未实现

## 1. 已实现 / 未实现

已实现：

- KOReader 插件骨架、`_meta.lua`、阅读中主菜单；
- 识别当前打开的流式 EPUB（固定版式与非 EPUB 文档会被拒绝）；
- 读取 XPointer 与可选百分比（取不到可靠百分比时显示“未知”，不伪造 0%）；
- 将当前进度导出为本地 JSON（`<settings>/baidupansync/exports/`）；
- 从导出目录选择记录导入，先持久化恢复点，再跳转；
- 跳转后在 `UIManager` 后续 tick 中读取**文档引擎实际 XPointer** 校验落点，不依赖 `rolling.xpointer` 缓存，也不等待源码未提供的“渲染完成事件”；
- 校验失败时回退原位置，并明确报告“不确定”，不记为成功；
- “撤销上次进度恢复”（只保留最近一次恢复点，不上传、不修改云端）。

未实现（后续阶段）：

- 完整 SHA-256 书籍身份、`bookId`、进度 schema 的云端字段（阶段 B）；
- 任何 WebDAV / 百度网盘连接、授权、上传下载（C1/C2 及以后）；
- 云端冲突处理、`writeId`、`baseRemoteFingerprint`（B/D）；
- 云端书库、下载、发布 sidecar（E/F）。

## 2. 安装

阶段 A 只做本地验证，安装方式与普通 KOReader 插件相同：

1. 将整个 `baidupansync.koplugin` 目录复制到目标 KOReader 的 `plugins/` 目录：
   - Kindle：`/mnt/us/koreader/plugins/`
   - Kobo：`.adds/koreader/plugins/`
   - macOS 开发环境：KOReader 检出目录的 `plugins/`
2. 重启 KOReader。
3. 打开一本 EPUB，在阅读界面菜单的“更多工具”（或对应分类）中找到“书籍与阅读进度同步”。

插件只注册阅读界面菜单（`is_doc_only = true`），阶段 A 不包含文件管理器入口。

## 3. 使用

菜单项：

```text
书籍与阅读进度同步
├── 导出当前阅读进度
├── 导入阅读进度
└── 撤销上次进度恢复
```

- **导出**：读取当前 XPointer 与百分比，写入导出目录，并显示文件路径。
- **导入**：列出导出目录中的 JSON（最多 10 条），选择后显示书名、导入位置、当前位置，确认后执行“保存恢复点 → 跳转 → 校验”。位置相同则提示无需跳转。
- **撤销**：把阅读位置恢复到上次导入前的位置；成功后清除恢复点。

数据位置（均为 KOReader 可写设置目录，不写入插件目录）：

```text
<settings>/baidupansync/restore_points.json   # {schemaVersion=1,data={last=...}}
<settings>/baidupansync/exports/*.json        # 导出记录，可手动复制进/出
```

macOS 开发环境的 `<settings>` 通常为 `~/Library/Application Support/koreader/settings`。

## 4. 本地记录格式（不是云端协议）

阶段 A 的记录用于同机往返验证，**不是**方案 4.1 的云端进度协议：它没有 `contentSha256`、没有 `book.id`、没有 `revision`/`writeId`。导入时只做弱身份检查（大小、可选 partial MD5、文件名或书名），并明确提示“不含完整内容摘要”。阶段 B 会用完整摘要身份替换该格式。

```json
{
  "schemaVersion": 1,
  "recordType": "local-progress",
  "book": {
    "title": "三国演义",
    "fileName": "sanguo.epub",
    "format": "epub",
    "size": 5242880,
    "partialMd5": "0123456789abcdef0123456789abcdef"
  },
  "progress": {
    "type": "xpointer",
    "value": "/body/DocFragment[1]/body/div/p[12]/text().5",
    "percent": 0.5832
  },
  "exportedAt": "2026-11-16T20:10:00+08:00"
}
```

校验规则：记录最大 64 KiB；`schemaVersion` 必须为 1；`recordType` 必须为 `local-progress`；`book.size` 为非负整数；书名/文件名不超过 512 UTF-8 字节、拒绝控制字符与非法 UTF-8；XPointer 非空、不超过 8 KiB、拒绝 NUL 与非法 UTF-8；`percent` 可省略，存在时必须为有限数值且在 0..1；`partialMd5` 若存在必须是 32 位小写十六进制。未知版本直接拒绝，不迁移、不覆盖。

## 5. 跳转校验与失败处理

- 跳转前必须先把恢复点原子写入本地状态文件（临时文件 + rename）；写入失败则**不跳转**。
- 跳转通过 `ReaderUI:handleEvent(Event:new("GotoXPointer", xp))` 发起。该调用是同步的，但没有渲染完成事件；因此在 `UIManager` 后续 tick 中读取 `document:getXPointer()`，用“解析后的页码相同”作为等价定位判据（页模式）；若引擎未规范化则用字符串完全相等。
- 校验有时间上限（默认 3 秒，100 ms 轮询）。超时视为**不确定**，不记为成功。
- 失败时尝试跳回原位置；回退也失败时报告双重不确定。两种情况都不会更新“成功”状态。
- 已知限制：滚动模式下的校验仅为页级；同步跳转本身无法被 UI 定时器中断，因此没有真正的“取消”能力。未在 Voyage / Clara BW 真机验证。

## 6. 测试

使用固定 KOReader 检出中的 LuaJIT/busted，不需要在 KOReader 检出内安装插件，也不会修改该检出：

```bash
KOREADER_DIR=/path/to/koreader ./spec/run.sh
# 可追加 busted 参数，例如只看进度服务：
KOREADER_DIR=/path/to/koreader ./spec/run.sh -f "progress service"
```

前置条件：KOReader 检出已完成 emulator 构建（存在 `base/build/*/staging/bin/luajit`），且 `test/juliet.epub` 测试书存在。运行使用临时 `KO_HOME` 与临时工作目录，结束后清理。

当前结果（2026-11-16，KOReader `c3e5f750b`，macOS emulator 构建）：

```text
54 tests / 6 files, 54 passed, 0 failed
```

覆盖：

- `spec/unit/progress_record_spec.lua`：字段类型、边界、非法 UTF-8、控制字符、percent、partial MD5、版本拒绝、编码/解码往返、弱身份匹配；
- `spec/unit/storage_spec.lua`：恢复点保存/读取/清除、原子写、未知版本与损坏文件不被覆盖、损坏恢复点报错；
- `spec/unit/export_store_spec.lua`：导出目录、文件名净化、重名、无效记录、越界路径拒绝；
- `spec/unit/progress_spec.lua`：捕获、percent 缺失、非 EPUB 拒绝、先存恢复点后跳转、上下文变化拒绝、存储失败不跳转、超时回退、回退失败、文档中途被替换时取消、撤销成功/缺失/错书；
- `spec/unit/progress_integration_spec.lua`：**真实 crengine + ReaderUI + juliet.epub** 的“捕获 → 翻页 → 导出 → 导入 → 恢复 → 撤销”闭环；
- `spec/unit/plugin_spec.lua`：插件 `main.lua`/`_meta.lua` 加载、菜单结构、无 EPUB 时禁用导入。

以下仍未执行，不能声称通过：

- macOS 图形界面手动“导出→翻页→导入→恢复”操作（集成测试为程序化调用同一服务，不是点击菜单）；
- Kindle Voyage、Kobo Clara BW 真机；
- 真机上的滚动模式、复杂 EPUB（多 DocFragment、脚注、大书）位置兼容性；
- 与内置 `kosync.koplugin` 同时启用时的相互影响。

## 7. 阶段 A 手动验收步骤

macOS（KOReader 模拟器）：

1. 安装插件并打开一本 EPUB，翻到约 30% 处。
2. 菜单 → 书籍与阅读进度同步 → 导出当前阅读进度，记下文件路径与百分比。
3. 翻到书末附近，再从菜单导入刚才的记录，确认弹窗显示的导入/当前位置不同。
4. 确认恢复；检查落点与导出时大致一致，并确认菜单“撤销上次进度恢复”可用。
5. 执行撤销，确认回到导入前的位置。
6. 关闭再打开该书，确认 KOReader 自身阅读位置没有异常，检查 `restore_points.json` 与 `exports/*.json` 结构。

Kindle Voyage / Kobo Clara BW：

1. 重复上述步骤，记录 KOReader 版本。
2. 分别测试页模式与滚动模式，记录滚动模式是否出现“页级校验通过但落点偏移”。
3. 断网状态下重复导出/导入（阶段 A 不依赖网络）。
4. 用 `metadata.epub.lua` 的修改时间确认插件未直接改写它（方案 1.1 禁止项）。

## 8. 已知问题与待确认项

- 滚动模式的落点校验只有页级精度；若真机上偏移明显，需要在阶段 A/B 之间补充引擎定位接口验证，不能靠百分比放宽判定。
- 导入记录的身份是弱校验（大小 + 文件名/书名 + 可选 partial MD5），同尺寸同名的不同内容不会被识别；这是阶段 A 的已知边界，阶段 B 用完整 SHA-256 取代。
- 中断/杀进程可能留下 `.tmp` 文件（不会被当作有效状态读取，但需手动清理）。
- 插件 UI 文案使用中文 `_()`；其他语言未提供翻译。
- `percent` 来自 `ReaderRolling:getLastPercent()`，滚动模式下源码已注明不准确；插件只显示、不用于判定。
