# 阶段 A 验收记录

> 项目：BaiduPanSync（KOReader 插件）  
> 对应方案：`BaiduPanSync_技术方案.md` V1.4 第 9 节阶段 A  
> 记录日期：2026-11-16  
> 状态：**用户已于 2026-11-17 确认阶段 A 通过，随后进入阶段 B（见 `阶段B验收记录.md`）。**
> 历史说明：本记录撰写时 GUI/真机手动验收尚未自动执行；用户确认代表其已接受阶段 A 的交付结果。

## 1. 阶段范围

方案阶段 A 要求：

- 初始化 KOReader 插件及菜单；识别当前 EPUB；
- 读取 XPointer 和百分比；导出/导入本地进度 JSON；
- 跳转与撤销恢复；不接入任何远端后端。

本阶段未实现（按方案留给后续阶段）：完整 SHA-256 书籍身份与 `bookId`、同步引擎、云端冲突、任何 WebDAV/百度网盘连接、授权、上传下载、书库、sidecar 发布。

## 2. 实现文件

| 文件 | 作用 |
|---|---|
| `baidupansync.koplugin/_meta.lua` | 插件元数据、版本 0.1.0 |
| `baidupansync.koplugin/main.lua` | 插件入口、菜单注册、导出/导入/撤销编排 |
| `baidupansync.koplugin/modules/progress.lua` | ProgressService：捕获、跳转、有限等待校验、回退、撤销、书籍上下文核对 |
| `baidupansync.koplugin/modules/progress_record.lua` | 阶段 A 本地记录 schema、严格校验、弱身份匹配、时间格式、UTF-8 校验 |
| `baidupansync.koplugin/modules/storage.lua` | 本地状态（`schemaVersion=1` 信封）、恢复点读写、未知版本/损坏文件保护 |
| `baidupansync.koplugin/modules/file_util.lua` | 递归建目录、临时文件 + 原子替换、限长读取 |
| `baidupansync.koplugin/modules/export_store.lua` | 导出目录、文件名净化、重名处理、导入列表与加载 |
| `baidupansync.koplugin/modules/errors.lua` | 统一错误结构 `{code,message,retryable,outcome}` 与错误码 |
| `baidupansync.koplugin/ui/progress_dialog.lua` | 导出结果、导入选择/确认、撤销确认、错误提示 |
| `baidupansync.koplugin/ui/menu.lua` | 仅阶段 A 的三项菜单 |
| `baidupansync.koplugin/spec/run.sh` | 针对固定 KOReader 检出的 busted 运行脚本（不修改检出） |
| `baidupansync.koplugin/spec/unit/*.lua` | 6 个 spec 文件，54 项测试 |
| `baidupansync.koplugin/spec/fixtures/fake_reader.lua` | 可控假 ReaderUI/引擎（含 XPointer 规范化、跳转失败、文档替换） |
| `baidupansync.koplugin/README.md` | 安装、使用、数据位置、限制、测试与手动验收步骤 |

## 3. 核心设计决定

1. **位置来源**：只调用 `ReaderRolling:getLastProgress()` 取 XPointer；百分比取 `getLastPercent()`，仅作显示，nil/NaN/无穷/越界时省略并显示“未知”。
2. **不信任 rolling 缓存**：跳转后读取 `document:getXPointer()`（引擎实际位置），用“解析后页码相同”作为页模式等价判据；字符串完全相同则记为 `exact`。不等待源码不存在的渲染完成事件。
3. **恢复点先落盘**：跳转前必须把原位置写入 `restore_points.json`（临时文件 + rename）；持久化失败则不跳转。
4. **失败不伪装成功**：3 秒（100 ms 轮询）内无法确认则返回 `UNCERTAIN`，尝试回退原位置；回退也失败时报告双重不确定。两种情况都不写“成功”状态。
5. **文档变化即停止**：每次校验都核对当前文档路径与大小；中途关闭/替换书籍返回 `CANCELLED`，不把结果应用到另一文档。
6. **严格输入校验**：记录 ≤64 KiB、未知 `schemaVersion` 拒绝、XPointer ≤8 KiB 且拒绝 NUL/非法 UTF-8、书名/文件名 ≤512 UTF-8 字节且拒绝控制字符、percent 必须有限且在 0..1。
7. **状态文件保护**：未知版本或损坏的 `restore_points.json` 保留原文件并报错，不当作空状态覆盖。
8. **记录不是云端协议**：阶段 A 记录带 `recordType="local-progress"`，无 `contentSha256`/`book.id`，导入时使用大小 + 可选 partial MD5 + 文件名/书名的弱校验，并在确认弹窗明确说明；阶段 B 将替换为完整摘要协议。

## 4. 自动测试

运行环境：

- KOReader：本地检出 `c3e5f750b`（2026-11-10）
- 运行时：该检出的 macOS emulator 构建，LuaJIT 2.1.1793383622
- 测试框架：busted 2.3.0（KOReader 检出内置）
- 临时 `KO_HOME` 与工作目录，测试结束清理；不修改 KOReader 检出、不访问真实书库

命令与结果：

```text
KOREADER_DIR=/Users/zhou/workcode/studyCode/koreader ./baidupansync.koplugin/spec/run.sh

54 tests / 6 files, 54 passed, 0 failed (约 0.8 s)
```

分文件覆盖：

| 文件 | 测试数 | 覆盖 |
|---|---:|---|
| `progress_record_spec.lua` | 19 | 字段类型/边界、非法 UTF-8、控制字符、percent、partial MD5、版本拒绝、编解码往返、弱身份匹配、时间格式 |
| `progress_spec.lua` | 15 | 捕获、percent 缺失、非 EPUB/固定版式拒绝、先存恢复点后跳转、上下文变化拒绝、存储失败不跳转、超时回退、回退失败、中途文档替换取消、撤销成功/缺失/错书 |
| `storage_spec.lua` | 6 | 空状态、保存/读取/清除、原子写、未知版本与损坏文件不覆盖、损坏恢复点报错 |
| `export_store_spec.lua` | 7 | 导出、文件名净化、重名、有效/无效列表、目录缺失、路径越界、加载时校验 |
| `progress_integration_spec.lua` | 3 | **真实 crengine + ReaderUI + juliet.epub**：捕获、导出→翻页→导入→恢复→撤销、错书拒绝 |
| `plugin_spec.lua` | 4 | `_meta`/`main` 加载、版本、状态目录、菜单结构、无 EPUB 时禁用导入 |

关键集成证据（真实引擎，非 mock）：

- 第 12 页捕获 → 翻到第 3 页 → 导入 → 引擎实际落点为第 12 页；
- 撤销 → 回到导入前的第 3 页；
- 恢复点写入 `restore_points.json`，撤销后清除；
- 全程未改写 `metadata.epub.lua`（测试未触发相关写入）。

## 5. API 兼容性记录

已按本机源码核实并在实现中使用：

| 调用 | 依据 | 使用方式 |
|---|---|---|
| `ReaderRolling:getLastProgress()` | `readerrolling.lua` 返回 `self.xpointer` | 捕获位置 |
| `ReaderRolling:getLastPercent()` | 同文件；滚动模式注明不准确 | 仅显示，取不到则省略 |
| `Event:new("GotoXPointer", xp)` → `ReaderRolling:onGotoXPointer` | 同步调用 `_gotoXPointer`，无完成事件 | 发起跳转 |
| `Document:getXPointer()` / `getPageFromXPointer()` | `credocument.lua` | 校验实际落点 |
| `UIManager:scheduleIn()` | `uimanager.lua` | 有限等待轮询 |
| `doc_settings:readSetting("partial_md5_checksum")` | KOSync 实现的 partial MD5 来源 | 弱匹配线索（可缺省） |
| `lfs` / `json` / `ffi/util` | KOReader 既有模块 | 存储、序列化、时间 |

未在阶段 A 使用但已核实的候选：`base/ffi/sha2.lua` 分块 SHA-256（阶段 B 使用）。

## 6. 尚未执行的验收

| 项目 | 状态 | 说明 |
|---|---|---|
| macOS GUI 手动“导出→翻页→导入→恢复” | 待执行 | 自动测试为程序化调用同一服务，不能替代点击菜单 |
| Kindle Voyage 真机 | 待执行 | 需记录 KOReader 版本、页/滚动模式、落点偏差 |
| Kobo Clara BW 真机 | 待执行 | 同上 |
| 复杂 EPUB（多 DocFragment、脚注、大书） | 待执行 | 验证 XPointer 规范化与页映射 |
| 与内置 `kosync.koplugin` 并存 | 待执行 | 只声明互不改配置，未实测相互影响 |
| 滚动模式落点精度 | 待执行 | 当前仅页级校验；若偏移明显需补充引擎接口验证 |

## 7. 手动验收步骤

macOS：

1. 将 `baidupansync.koplugin` 复制到 KOReader `plugins/`，重启。
2. 打开 EPUB，翻到约 30%，导出进度，记录路径/百分比。
3. 翻到书末，导入刚导出的记录，确认弹窗显示的导入/当前位置不同。
4. 确认恢复；核对落点与导出时一致；“撤销上次进度恢复”可用。
5. 撤销，核对回到导入前位置。
6. 检查 `<settings>/baidupansync/restore_points.json` 与 `exports/*.json`；确认 `metadata.epub.lua` 修改时间未因插件改变。

Kindle Voyage / Kobo Clara BW：

1. 重复上述 2–6，记录设备型号与 KOReader 版本。
2. 页模式与滚动模式各测一次，记录滚动模式是否有页级通过但落点偏移。
3. 断网重复一次（阶段 A 不依赖网络）。
4. 若安装后菜单未出现，检查插件目录名必须为 `baidupansync.koplugin`，并查看 KOReader 日志中的插件加载错误。

## 8. 已知限制

- 记录身份为弱校验，同大小同名的不同内容无法区分；这是阶段 A 的明确边界，阶段 B 用完整 SHA-256 替代。
- 滚动模式验证只有页级精度。
- 同步跳转无法被 UI 定时器中断，阶段 A 不提供真正的取消操作；取消仅在文档被关闭/替换时由校验循环检测。
- 进程被强杀可能遗留 `.tmp` 文件；该文件不会被当作状态读取，但需手动清理。
- UI 文案仅中文；未提供其他语言翻译。
- 插件未提交 git（当前仓库状态由用户决定），也未在真机安装验证。

## 9. 决策门

阶段 A 自动测试通过，但按方案要求仍需：

1. 用户在 macOS GUI 与至少一台目标真机上完成第 7 节手动验收；
2. 记录设备、KOReader 版本、测试结果与限制；
3. 用户明确确认后，才可进入阶段 B（完整 SHA-256 身份与本地同步引擎）。

在此之前不得声称阶段 A 整体通过，不得提前实现 C1/C2 适配器或任何云端功能。

## 10. 2026-11-17 后续修复

阶段 B/C1 复查已修复：导航在后续 tick 校验、滚动模式不再仅凭同页成功，生产撤销要求完整 SHA-256，文档上下文增加对象/mtime 核对。以上替代本记录中的历史弱校验限制，详见阶段 B/C1 记录。真机验收状态不变。

## 11. 2026-11-18 云端进度同步真机确认（0.9.1）

用户确认：Kobo 与 Kindle 真机上，WebDAV 与百度网盘的**云端阅读进度同步闭环成功**。这验证了本阶段位置读取/恢复能力在真实设备、真实同步流程中的可用性。

但这不等于第 6 节本地导出→翻页→导入→恢复专项、XPointer 落点精度（含滚动模式）、复杂 EPUB 与 macOS GUI 手动项已逐项验收；这些仍为待执行。云端同步成功只覆盖其实际走到的恢复路径，不代为推断落点偏差与边界精度。
