# baiduPanSync

基于 KOReader 的书籍与阅读进度同步插件（目标后端：自建 WebDAV、百度网盘）。

- 技术方案：[BaiduPanSync_技术方案.md](BaiduPanSync_技术方案.md)（V1.7，开发基线）
- 文档分析：[分析结果.md](分析结果.md)
- 插件目录：[baidupansync.koplugin](baidupansync.koplugin)（当前版本 0.7.0：WebDAV 进度同步、当前 EPUB 上传、书库下载）
- 安装/使用/测试说明：[baidupansync.koplugin/README.md](baidupansync.koplugin/README.md)
- 阶段 A 验收记录：[阶段A验收记录.md](阶段A验收记录.md)（已通过）
- 阶段 B 验收记录：[阶段B验收记录.md](阶段B验收记录.md)

## 当前状态

C1 已由用户确认通过。D/E/F 已连续实现，支持 WebDAV 云端进度上传/查询/应用、当前 EPUB 发布和云端书库下载，包含 home_dir、递归同名比较、安全覆盖/重命名。此前完整插件基线测试 186/186 通过；当前 C2 独立回归与真实局域网 HTTP 套接字验证通过，百度真实应用及目标设备验收待完成。当前 Windows 的 Node 测试受符号链接权限限制未全过，详见 [阶段C2验收记录.md](阶段C2验收记录.md)。未推进百度书籍/进度专项及 G。WebDAV 主线详见 [阶段DEF验收记录.md](阶段DEF验收记录.md)。

## 运行测试

```bash
KOREADER_DIR=/path/to/koreader ./baidupansync.koplugin/spec/run.sh
KOREADER_DIR=/path/to/koreader ./baidupansync.koplugin/spec/run.sh --bench
KOREADER_DIR=/path/to/koreader npm --prefix serve run test:plugin
```

## 本地 WebDAV 测试服务

已提供零依赖 Node.js 服务：[serve/README.md](serve/README.md)。修改 `serve/config.json` 的端口、账户和存储目录后，运行 `node serve/server.js`，可测试插件的 C1 上传下载及条件写入。

0.7.0 新增百度 C2：应用配置、二维码局域网页面、OOB 授权码交换、私有凭据保存、随机测试 JSON 上传/回读/删除及显式后端选择。真实百度与真机验收待完成，百度书籍/进度同步尚未开放。

0.6.7 云端书库改为全屏封面网格，支持三列书架、搜索、长按详情、底部分页及滑动翻页；新上传书籍附带封面缩略图，旧书可重新上传补充。

0.6.6 云端书库优先展示 EPUB 元数据书名，支持中文；缺少书名时回退到文件名，按展示书名排序。

0.6.5 移除本地进度备份入口与导入、导出操作；云端书库新增搜索、书名/大小排序、简洁书籍行与分页信息。旧备份文件保留。

0.6.4 主页精简为五个入口，阅读进度、本地备份、连接设置分别集中到分组页面，支持返回主页。

0.6.3 兼容剩余空间接口的两返回值和三返回值形式，保留空间不足拦截，并在查询失败时显示目录与原因。

0.6.2 修复同名检查完成时误触发取消的问题；下载冲突等待用户选择，并显示同名书籍的完整本地路径。

0.6.1 新增独立全屏插件主页；操作完成后保留主页，云端书库下载时保留列表和当前页，减少反复进入菜单。
