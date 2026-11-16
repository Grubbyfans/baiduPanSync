# baiduPanSync

基于 KOReader 的书籍与阅读进度同步插件（目标后端：自建 WebDAV、百度网盘）。

- 技术方案：[BaiduPanSync_技术方案.md](BaiduPanSync_技术方案.md)（V1.4，开发基线）
- 文档分析：[分析结果.md](分析结果.md)
- 插件目录：[baidupansync.koplugin](baidupansync.koplugin)（当前实现阶段 A：本地进度导出/导入/恢复校验/撤销）
- 阶段 A 说明与安装、测试步骤：[baidupansync.koplugin/README.md](baidupansync.koplugin/README.md)
- 阶段 A 验收记录：[阶段A验收记录.md](阶段A验收记录.md)

## 当前状态

阶段 A 已实现并通过本地测试（KOReader `c3e5f750b` emulator，54 项 busted 测试，含真实 crengine 的捕获→导出→翻页→导入→恢复→撤销闭环）。阶段 B 及之后尚未开始；未接入任何远端后端。

## 运行测试

```bash
KOREADER_DIR=/path/to/koreader ./baidupansync.koplugin/spec/run.sh
```
