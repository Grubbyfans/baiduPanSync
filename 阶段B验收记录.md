# 阶段 B 验收记录

> 项目：BaiduPanSync（KOReader 插件）  
> 对应方案：`BaiduPanSync_技术方案.md` V1.4 第 9 节阶段 B  
> 记录日期：2026-11-17  
> 状态：**实现完成，自动测试通过；GUI 与真机手动验收尚未执行。不得进入 C1，等待用户确认。**

## 1. 阶段范围

方案阶段 B 要求：

- 完整 SHA-256 书籍身份与缓存失效规则；partial MD5 仅作辅助线索；
- JSON schema 校验、远端记录指纹、`writeId`、展示用 `revision`、冲突弹窗、恢复点持久化；
- 后端配置身份与 `backendId + bookId` 基线隔离，验证切换目标不复用错误基线；
- 验收：两台设备手动交换 JSON 可恢复同一 EPUB，错误书籍和坏 JSON 被拒绝；完成哈希性能与取消记录、本地状态版本检查、任务状态转换及失败边界验证。

本阶段仍**不连接任何远端后端**，不实现 WebDAV/百度适配器；网络与云端写入属于 C1/C2/D。

## 2. 实现文件

| 文件 | 作用 |
|---|---|
| `modules/hash.lua` | 分块 SHA-256、进度回调、取消、文件前后状态复核、完成回调只触发一次 |
| `modules/book_identity.lua` | 完整摘要身份、缓存（路径+大小+mtime）、缓存失效/重建、取消不缓存 |
| `modules/random.lua` | `/dev/urandom` 随机源；不可用时报错，不使用 `math.random` |
| `modules/config_store.lua` | `config.json` 版本化信封；全局 `deviceId` 只生成一次 |
| `modules/progress_record.lua` | 云端进度 JSON schemaVersion=1、严格校验、原始字节指纹、记录构建 |
| `modules/backend_identity.lua` | WebDAV/百度身份归一化与无歧义编码，计算 `backendId` |
| `modules/sync_state.lua` | `backendId + bookId` 基线、present/absent 标记、版本损坏保护 |
| `modules/conflict.lua` | 位置指纹、原始字节指纹、首次关联/变化/同 revision 冲突分类 |
| `modules/task.lua` | 任务状态机与合法转换、终态、取消、历史记录 |
| `modules/sync_engine.lua` | 本地手动交换引擎：导出/导入、revision、writeId、回读校验、基线提交 |
| `modules/progress.lua` | 增加任务状态上报（persisting_restore/applying/checking_position） |
| `ui/progress_dialog.lua` | 哈希进度/取消、冲突确认弹窗、记录列表 |
| `main.lua` | 装配身份/配置/基线/引擎，导出/导入/撤销 UI |
| `spec/unit/*.lua` | 15 个 spec，121 项测试 |
| `spec/bench/hash_bench.lua` | 哈希吞吐与取消基准 |

## 3. 核心设计决定

1. **身份只认完整字节**：`bookId = contentSha256`；`partialMd5` 仅在旧接口中作为线索，不参与判定。
2. **哈希可取消、可复核**：1 MiB 分块、每块让出；取消返回 `CANCELLED` 且不缓存；结束后重新读取 size/mtime，变化则放弃摘要。
3. **缓存是派生数据**：`hash_cache.json` 损坏/未知版本时忽略并重建；与 config/sync_state 的“保留原文件”策略不同，理由在代码与 README 中写明。
4. **全局设备身份**：`deviceId` 首次生成后不变；`writeId` 每次导出重新生成；二者均来自 OS 随机源。
5. **基线隔离**：`backendId + bookId` 两级键；`remote_state` 区分 present/absent；读错误不写成 absent。
6. **冲突判据**：以记录原始字节 SHA-256 为主，`revision` 仅展示；同 revision 不同内容单独告警。
7. **先确认后写入**：导入必须经过确认弹窗；用户取消即 `cancelled`，不产生跳转、不更新基线。
8. **提交顺序**：导出先写文件、回读校验，再提交基线；导入先应用成功，再提交基线。任一步失败都不谎报完整成功，`uncertain` 单独返回。
9. **状态机**：非法转换被拒绝；任务在文档被关闭/替换时由 ProgressService 的上下文检查中止。
10. **手动交换通道**：使用内部 `backendId = sha256("baidupansync.manual-exchange.v1")` 复用基线/冲突逻辑，与后续真实 WebDAV/百度基线隔离，不是用户可选后端。

## 4. 自动测试

环境：

- KOReader 检出 `c3e5f750b`（2026-11-10），macOS emulator 构建，LuaJIT 2.1.1793383622
- busted 2.3.0；临时 `KO_HOME` 与工作目录，结束后清理；不修改 KOReader 检出

命令与结果：

```text
KOREADER_DIR=/Users/zhou/workcode/studyCode/koreader ./baidupansync.koplugin/spec/run.sh

121 tests / 15 files, 121 passed, 0 failed (约 0.84 s)
```

分文件：

| spec | 数量 | 重点 |
|---|---:|---|
| `hash_spec.lua` | 8 | 已知摘要、任意分块一致、进度单调、取消、文件中途变化、回调抛错 |
| `book_identity_spec.lua` | 8 | 首次计算、缓存命中、文件变化重算、失效、缓存损坏重建、取消不缓存 |
| `random_spec.lua` | 4 | OS 随机源、token、非法字节数 |
| `config_store_spec.lua` | 6 | deviceId 只生成一次、持久化、损坏/未来版本保留、非法已存值 |
| `progress_record_spec.lua` | 14 | id==sha256、摘要/大小/revision/writeId/deviceId/updatedAt、UTF-8、percent、原始指纹 |
| `backend_identity_spec.lua` | 9 | URL 归一化、大小写语义、凭据/查询/片段拒绝、编码歧义、百度字段隔离 |
| `sync_state_spec.lua` | 7 | 基线存取、backend/book 隔离、absent 标记、删除、损坏/未来版本不覆盖 |
| `conflict_spec.lua` | 8 | 位置指纹、首次关联、unchanged、同 revision 冲突、变化/删除 |
| `task_spec.lua` | 8 | 导出/导入生命周期、非法转换、终态、取消、回调异常 |
| `sync_engine_spec.lua` | 11 | 导出回读、revision 递增、缓存命中、取消、导入、错书、坏 JSON、确认取消、基线提交失败 |
| `export_store_spec.lua` | 7 | 导出目录、文件名净化、重名、无效记录、越界路径 |
| `progress_spec.lua` | 16 | 捕获、跳转校验、回退、状态上报、撤销、上下文失效 |
| `storage_spec.lua` | 6 | 恢复点、原子写、损坏/未知版本保护 |
| `progress_integration_spec.lua` | 5 | **真实 crengine + ReaderUI + juliet.epub 的双设备交换** |
| `plugin_spec.lua` | 4 | 插件加载、版本、菜单、无 EPUB 时禁用 |

关键集成证据（真实引擎，非 mock）：

- 设备 A 第 12 页导出 → 设备 B 翻到第 3 页导入 → 实际落点第 12 页；B 的 `sync_state` 写入对应 `backendId + bookId` 基线；撤销回到第 3 页；
- 设备 B 的设备 ID 与 A 不同，记录中的 `sync.deviceId` 为 A 的快照；
- 修改记录中的 `book.id`/`contentSha256` 后导入：拒绝，位置不变；
- 截断 JSON：拒绝，位置不变；
- A 再导出（revision+1）→ B 导入分类为 `remote_changed`，仍需确认。

## 5. 哈希性能与取消（macOS 桌面）

命令：

```text
KOREADER_DIR=... ./baidupansync.koplugin/spec/run.sh --bench
```

结果（2026-11-17，macOS Apple Silicon emulator，1 MiB 分块）：

```text
BENCH   10 MB:   0.066 s   151.3 MB/s  chunks=11
BENCH  100 MB:   0.629 s   159.0 MB/s  chunks=101
CANCEL after 1 chunk(s): 0.000 s, code=CANCELLED
```

说明：

- 这是桌面模拟器数据，**不能代表** Kindle Voyage / Kobo Clara BW；真机耗时、进度刷新、取消响应仍待记录；
- 方案中的“100 MB/20 秒”只是候选目标，本记录不声称已达或未达；
- 取消在下一分块边界生效；同步调用不可中断的边界已在 README 说明。

## 6. 手动验收（待执行）

两台设备（或两个独立设置目录）按 README 第 8 节执行，至少覆盖：

| 项目 | 预期 | 状态 |
|---|---|---|
| A 导出（首次） | 显示哈希进度，完成后生成带完整摘要的 JSON | 待执行 |
| A 再次导出 | 不再显示哈希进度（缓存命中），revision +1 | 待执行 |
| B 导入 A 的记录 | 内容摘要一致，落点正确，B 生成基线 | 待执行 |
| B 导出后 A 导入 | `remote_changed` 提示并要求确认 | 待执行 |
| 不同内容 EPUB 导入 | 拒绝，位置不变 | 待执行 |
| 破坏 JSON 导入 | 拒绝，位置不变 | 待执行 |
| 大书哈希 | 记录耗时/MB/s、进度刷新、取消响应 | 待执行 |
| Kindle Voyage / Kobo Clara BW | 同上全部 | 待执行 |
| `metadata.epub.lua` | 未被插件直接改写 | 待执行 |

## 7. 已知限制

- 手动交换的 `revision` 是本地通道计数，不是远端 revision；真实取值需 C1 接入后由远端记录决定。
- 手动交换没有远端读取、条件写入和回读远端内容；`baseRemoteFingerprint` 只针对交换文件。
- 完整 SHA-256 对大书首次导出有成本；真机预算未定。
- 缓存只按 size/mtime 失效，保留属性的外部篡改无法识别（方案已接受该限制）。
- 滚动模式落点仍是页级校验；`percent` 仅展示。
- 无凭据、无网络、无 Token；也无 WebDAV/百度 UI。
- 阶段 A 的 `local-progress` 记录被有意拒绝（无 `sync`/`contentSha256`），升级后需重新导出；阶段 B 不做自动迁移。

## 8. 决策门

阶段 B 自动测试通过，但按方案要求仍需：

1. 用户在 macOS GUI 与至少两台设备/两个独立设置目录完成第 6 节手动验收；
2. 记录设备、KOReader 版本、哈希耗时与取消表现；
3. 用户明确确认后，才可进入 C1（WebDAV 接入与统一适配器），且 C1 仍需先完成方案第 5.5 节 TLS 门槛验证。

在此之前不得声称阶段 B 整体通过，不得提前实现 WebDAV/百度适配器或云端写入。
