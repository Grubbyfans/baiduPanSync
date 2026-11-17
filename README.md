# baiduPanSync

基于 KOReader 的书籍与阅读进度同步插件（目标后端：自建 WebDAV、百度网盘）。

- 技术方案：[BaiduPanSync_技术方案.md](BaiduPanSync_技术方案.md)（V1.4，开发基线）
- 文档分析：[分析结果.md](分析结果.md)
- 插件目录：[baidupansync.koplugin](baidupansync.koplugin)（当前实现阶段 B：完整 SHA-256 身份、云端进度 JSON、手动双设备交换）
- 安装/使用/测试说明：[baidupansync.koplugin/README.md](baidupansync.koplugin/README.md)
- 阶段 A 验收记录：[阶段A验收记录.md](阶段A验收记录.md)（已通过）
- 阶段 B 验收记录：[阶段B验收记录.md](阶段B验收记录.md)

## 当前状态

阶段 A 已通过。阶段 B 已实现并通过本地自动测试（KOReader `c3e5f750b` emulator，121 项测试，含真实 crengine 的双设备 JSON 交换闭环）；真机与 GUI 手动验收仍待执行。未接入任何远端后端，WebDAV/百度适配器属于后续阶段。

## 运行测试

```bash
KOREADER_DIR=/path/to/koreader ./baidupansync.koplugin/spec/run.sh
KOREADER_DIR=/path/to/koreader ./baidupansync.koplugin/spec/run.sh --bench
```
