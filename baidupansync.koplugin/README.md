# BaiduPanSync（KOReader 插件）

按《BaiduPanSync_技术方案.md》V1.4 实现：阶段 A（本地位置闭环）已完成并经用户确认；当前版本为**阶段 B：完整 SHA-256 书籍身份 + 本地手动交换引擎**。不连接任何远端后端，不包含 WebDAV/百度适配器。

- 插件版本：0.2.0（阶段 B）
- 目标运行时：KOReader（LuaJIT）；已在本地 KOReader 检出 `c3e5f750b`（2026-11-10）的 macOS 模拟器环境验证
- 阶段范围：方案第 9 节阶段 B；C1/C2 及之后的网络与云端功能尚未开始

## 1. 已实现 / 未实现

已实现：

- 完整 EPUB 的 SHA-256 内容身份（`bookId == contentSha256`）；
- 分块增量哈希：处理块之间让出事件循环，显示进度、可取消；取消不返回摘要、不写缓存；哈希前后重新读取文件状态，变化则放弃；
- 摘要缓存：按 `路径 + 大小 + mtime` 失效；缓存损坏或版本未知时忽略并重建（缓存是派生数据，不是权威状态）；
- 云端进度 JSON（schemaVersion=1）：`book`/`progress`/`sync` 全字段校验，`book.id == book.contentSha256`、`revision`、`writeId`、`deviceId`、`updatedAt` 严格校验；
- 全局 `deviceId`：首次生成并持久化到 `config.json`，之后不再变化；随机源为 `/dev/urandom`，不可用时报错而不是退化；
- `writeId`：每次导出使用系统随机源重新生成；
- `backendId`：按类型 + 规范化目标 + 账户做无歧义编码后 SHA-256；WebDAV 只做方案确认的等价归一化，拒绝内嵌凭据/查询/片段；
- 基线存储：按 `backendId + bookId` 隔离；`remote_state` 显式区分 `present/absent`；基线含 `baseRevision`、远端原始字节指纹、位置指纹、writeId；
- 冲突分类：首次关联、未变化、记录变化、同 revision 不同内容、记录出现/缺失；导入确认弹窗显示冲突类型与本地/导入差异；
- 任务状态机：`idle → preparing → reading_remote → awaiting_confirm → rechecking → persisting_restore → applying → checking_position → committing_local → done`，另有 `failed/cancelled/uncertain`；非法转换被拒绝；
- 手动交换引擎：导出=哈希→写文件→回读校验→提交本地基线；导入=校验记录→校验当前书身份→冲突确认→复核身份→保存恢复点→跳转/校验→提交基线；
- 保留“撤销上次进度恢复”。

未实现（后续阶段）：

- WebDAV / 百度网盘适配器、连接配置、授权（C1/C2）；
- 远端读取/写入、条件写入、dlink 下载、sidecar 发布（C1/C2/D/E/F）；
- 远端书库与下载（F）；
- 与真实远端的 `baseRemoteFingerprint` 基线（当前手动交换通道使用内部 manual backendId）。

## 2. 安装

1. 将整个 `baidupansync.koplugin` 目录复制到目标 KOReader 的 `plugins/` 目录（Kindle `/mnt/us/koreader/plugins/`，Kobo `.adds/koreader/plugins/`，macOS 为 KOReader 检出的 `plugins/`）。
2. 重启 KOReader。
3. 打开一本 EPUB，阅读菜单 →“更多工具”→“书籍与阅读进度同步”。

## 3. 使用

```text
书籍与阅读进度同步
├── 导出当前阅读进度
├── 导入阅读进度
└── 撤销上次进度恢复
```

- **导出**：首次对该书导出会计算完整 SHA-256（显示进度、可点按取消）；之后命中缓存则直接导出。导出文件包含完整内容摘要、revision、writeId、deviceId、时间。
- **导入**：列出导出目录中的有效记录；确认弹窗显示内容摘要、导入/当前位置、revision、设备、时间、冲突类型；确认后先保存恢复点，再跳转并校验，成功后才更新本地基线。
- **撤销**：回到上次导入前的位置；成功后清除恢复点，不上传或修改任何远端数据。

数据位置（KOReader 可写设置目录下的 `baidupansync/`）：

```text
config.json          # {schemaVersion=1,data={deviceId=...}}
hash_cache.json      # 摘要缓存（派生数据，可删除）
sync_state.json      # {schemaVersion=1,data={baselines={backendId={bookId=...}}}}
restore_points.json  # {schemaVersion=1,data={last={book,position,...}}}
exports/*.json       # 云端 schema 的进度记录（手动复制进/出）
```

## 4. 云端进度 JSON（schemaVersion=1）

```json
{
  "schemaVersion": 1,
  "book": {
    "id": "<64 位小写十六进制，等于 contentSha256>",
    "title": "三国演义",
    "format": "epub",
    "size": 5242880,
    "contentSha256": "<64 位小写十六进制>"
  },
  "progress": {
    "type": "xpointer",
    "value": "<KOReader XPointer>",
    "percent": 0.5832
  },
  "sync": {
    "revision": 3,
    "writeId": "<每次写入重新生成的随机标识>",
    "deviceId": "kindle-voyage-<随机标识>",
    "updatedAt": "2026-11-16T20:10:00+08:00"
  }
}
```

校验：记录 ≤64 KiB；`schemaVersion` 必须为 1（未知版本拒绝）；`book.id == book.contentSha256` 且为 64 位小写十六进制；`format == "epub"`；`size` 非负整数；`title` 非空、≤512 UTF-8 字节、拒绝控制字符与非法 UTF-8；XPointer 非空、≤8 KiB、拒绝 NUL 与非法 UTF-8；`percent` 可省略，存在时必须有限且在 0..1；`revision` 正整数；`writeId`/`deviceId` 非空 ≤128 字节；`updatedAt` 必须为带 UTC 偏移的 ISO-8601。

`revision` 与 `updatedAt` 只用于展示/诊断，冲突判定使用**记录原始字节的 SHA-256 指纹**；时间戳和设备时钟不参与新旧判断。

## 5. 哈希、缓存与取消

- 分块大小默认 1 MiB；每块后 `schedule` 让出，UI 可刷新和响应取消。
- 进度对话框为 KOReader 的 `ProgressbarDialog`；点按后选择“取消”即置取消标志，哈希循环在下一块边界停止，返回 `CANCELLED`，不返回、不缓存不完整摘要。
- 哈希开始和结束都会读取文件 size/mtime；中途变化返回 `CONFLICT`。
- 缓存条目包含路径、size、mtime、sha256、computed_at；只有 size 与 mtime 都匹配才复用。
- 缓存文件损坏、结构非法或版本未知时**按缓存未命中处理并重建**；它不是 config/sync_state 那样的权威状态，因此不要求保留。
- `partial MD5` 仍是可选辅助线索，不参与身份判定。

## 6. 基线与冲突

基线按 `backendId + bookId` 保存，不按书名或单独 bookId：

```json
{
  "remote_state": "present",
  "base_revision": 3,
  "base_remote_fingerprint": "<远端记录原始字节 SHA-256>",
  "last_progress_fingerprint": "<仅 XPointer 的指纹，不含 percent>",
  "updated_at": "2026-11-16T20:10:00+08:00",
  "last_write_id": "<最后一次确认的 writeId>"
}
```

冲突类型与含义：

| 类型 | 含义 | 行为 |
|---|---|---|
| `first_contact` | 本地无基线、存在记录 | 首次关联，必须确认 |
| `unchanged` | 指纹与基线一致 | 仍需确认是否恢复（位置可能不同） |
| `remote_changed` | 指纹不同且 revision 不同 | 提示记录变化，确认后关联 |
| `same_revision_different_record` | revision 相同但指纹不同 | 并发迹象，明确告警 |
| `remote_created` / `remote_deleted` | 基线为 absent 但记录出现 / 基线为 present 但记录缺失 | 需要确认或停止 |

手动文件交换使用内部固定 `backendId = sha256("baidupansync.manual-exchange.v1")`，与阶段 C1 的真实后端基线天然隔离；它不是用户可选后端。

## 7. 测试

```bash
# 单元 + 真实引擎集成测试
KOREADER_DIR=/path/to/koreader ./spec/run.sh

# 只看某个 spec
KOREADER_DIR=/path/to/koreader ./spec/run.sh -f "sync_engine"

# 哈希吞吐/取消基准（仅桌面模拟器，不代表真机）
KOREADER_DIR=/path/to/koreader ./spec/run.sh --bench
BPS_BENCH_MB=10,100,300 ./spec/run.sh --bench
```

当前结果（2026-11-17，KOReader `c3e5f750b`，macOS emulator）：

```text
121 tests / 15 files, 121 passed, 0 failed
BENCH   10 MB:   0.066 s   151.3 MB/s
BENCH  100 MB:   0.629 s   159.0 MB/s
CANCEL after 1 chunk(s): 0.000 s, code=CANCELLED
```

覆盖：哈希分块/取消/文件变化、身份缓存与失效、设备 ID 持久化、JSON schema 边界与非法 UTF-8、404/损坏状态不覆盖、backendId 归一化与歧义、基线隔离、冲突分类、任务状态机、导出/导入/基线提交失败/确认取消，以及 **真实 crengine + ReaderUI + juliet.epub 的双设备 JSON 交换闭环**。

## 8. 阶段 B 手动验收步骤

需要两台设备（或两台 KOReader 实例）各自有独立设置目录：

1. 设备 A 打开同一本 EPUB，翻到约 40%，导出进度；首次导出应显示哈希进度，完成后记录文件路径/摘要前缀/revision。
2. 再次导出：不应再出现哈希进度（命中缓存），revision 增加。
3. 把 A 的 JSON 复制到设备 B 的 `settings/baidupansync/exports/`（或用同一导出目录模拟）。
4. 设备 B 打开同一 EPUB（内容必须完全一致），翻到其他位置后导入该记录：
   - 确认弹窗显示相同内容摘要；
   - 确认恢复后落点正确；
   - B 的 `sync_state.json` 出现对应 `backendId + bookId` 基线。
5. B 再导出，revision 应在 A 的记录上 +1；A 导入 B 的记录时应显示 `remote_changed` 并再次确认。
6. 换一本内容不同的 EPUB 导入同一记录：必须提示完整摘要不一致并拒绝，位置不变。
7. 手工破坏一个 JSON（截断/改字段）后导入：必须拒绝且不跳转。
8. 大书（约 100 MB）导出一次，记录哈希耗时、进度是否刷新、取消响应；Kindle Voyage / Kobo Clara BW 上分别记录。
9. 确认 `metadata.epub.lua` 未被插件直接改写。

## 9. 已知限制与待确认项

- 当前 `revision` 是“手动交换通道”的本地写入计数，不是远端服务器 revision；C1 接入真实后端后由远端记录决定。
- 手动交换的 baseline 不校验远端（没有远端），只校验交换文件与当前书身份；真正的条件写入/回读属于 C1/D。
- 完整 SHA-256 每次内容变化都要重新计算；大书首次导出在低性能设备上的耗时尚未记录。
- 桌面基准约 160 MB/s，真机（Voyage / Clara BW）未测，不能据此承诺 100 MB/20 秒。
- 滚动模式落点校验仍为页级（阶段 A 已记录）；`percent` 仅展示。
- 无网络请求、无凭据、无 Token；也没有 i18n 之外的多语言文案。
- 阶段 A 的 `recordType="local-progress"` 记录不再被接受（缺少 `sync`/`contentSha256`）；升级后需重新导出。这是方案“不宣称与早期草案兼容”的预期行为。
