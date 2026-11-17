# 插件 WebDAV 测试服务

使用 Node.js 内置模块，无需安装 npm 依赖。需要 Node.js 18 或更高版本。

## 启动

```sh
cd serve
npm start
# 或在项目根目录：
node serve/server.js
# 指定其他配置：
node serve/server.js serve/config.local.json
```

默认地址 `http://127.0.0.1:8080/sync/`，用户名 `test`，密码 `change-me`，存储目录为 `serve/data`，首次启动自动创建。配置中的相对文件路径均相对于**配置文件所在目录**解析。

建议复制 `config.json` 为已忽略的 `config.local.json`，按需修改：

```json
{
  "host": "0.0.0.0",
  "port": 8080,
  "directory": "/你的绝对路径/插件测试书库",
  "rootPath": "/sync/",
  "username": "test",
  "password": "替换为你的测试密码",
  "maxUploadBytes": 536870912,
  "tls": null
}
```

- `host`：默认只允许本机；真机测试可改为电脑的局域网 IP 或 `0.0.0.0`。
- `port`：监听端口，默认 8080。
- `directory`：实际保存上传文件的目录，可以是绝对路径或相对路径。
- `rootPath`：WebDAV URL 前缀，必须以 `/` 开头并结束；仅允许普通 ASCII 路径段。
- `username` / `password`：HTTP Basic 认证，不能为空。
- `maxUploadBytes`：单文件上传上限，默认 512 MiB。
- `tls`：默认 HTTP；HTTPS 可设为 `{ "cert": "./server.pem", "key": "./server.key" }`，证书需包含访问域名/IP 的 SAN，并被插件使用的 CA 文件信任。

HTTP 会明文传输密码和文件，仅用于可信局域网；不要将此测试服务暴露到公网。请使用专门的测试目录，操作会真实写入、替换和删除文件。服务拒绝路径穿越和目录内符号链接；运行期间不要由其他程序修改存储目录，不要用多个服务进程共享同一目录。

## 在插件中连接

1. 在 KOReader 中打开“书籍与阅读进度同步”→“WebDAV 配置（C1）”。
2. 根 URL 填 `http://电脑局域网IP:8080/sync/`，账户与配置一致；不要填 `0.0.0.0`，真机上也不要填 `127.0.0.1`。
3. 选择“WebDAV 连接与测试文件验证”。
4. 成功后目录下会留下空的 `.baidupansync-probe-...` 测试目录；探测 JSON 会被插件清理。

插件 0.6.0 已实现 D/E/F，可直接用本服务测试云端进度、EPUB 发布和书库下载；书籍下载前需在 KOReader 设置根目录。

## 简单上传下载

在项目根目录运行，账户按实际配置替换：

```sh
curl -u test:change-me -X MKCOL http://127.0.0.1:8080/sync/books
curl -u test:change-me -T ./测试.epub http://127.0.0.1:8080/sync/books/test.epub
curl -u test:change-me http://127.0.0.1:8080/sync/books/test.epub -o /tmp/test.epub
curl -u test:change-me -X PROPFIND -H 'Depth: 1' http://127.0.0.1:8080/sync/books/
```

支持 OPTIONS、HEAD、GET、MKCOL、PROPFIND（Depth 0/1）、PUT、DELETE。返回基于完整 SHA-256 的强 ETag，支持条件创建 `If-None-Match: *` 和强 `If-Match` 替换/删除。写入使用临时文件，完整接收后原子替换；DELETE 仅删除文件或空目录，拒绝删除服务根目录。所有请求在单进程内串行处理，条件检查不会被另一个请求插入。它是测试服务器，不提供完整 WebDAV 锁、Range、MOVE、浏览器管理页面或多进程并发保证。

## 自动测试

```sh
cd serve
npm test
```

测试使用系统临时目录和随机回环端口，不修改配置中的存储目录。

也可以让已有插件自动用例连接本服务（需要本地 KOReader 构建；插件用例固定使用 `u` / `p`，请为该测试单独配置）：

```sh
BPS_DAV_TEST_URL=http://127.0.0.1:8080/sync/ KOREADER_DIR=/path/to/koreader ./baidupansync.koplugin/spec/run.sh
```

验证记录：Node.js v18.20.4 下 9 个行为场景通过（测试报告含父用例共 10 项）；KOReader C1 自动探测已连接此 Node 服务通过上传、stat、枚举、下载、条件创建/替换及清理。该次插件测试为 144 通过、1 个独立 TLS 夹具测试跳过；不代表真机或本服务 HTTPS 配置已验收。

一键运行使用此 Node 服务的完整插件联调（临时目录、随机回环端口，并自动启动 TLS 夹具）：

```sh
KOREADER_DIR=/path/to/koreader npm --prefix serve run test:plugin
```

0.6.0 完整插件回归为 180/180 通过，包括实际 Node 服务 + crengine 的书籍发布、下载、云端进度恢复及撤销；Node 服务自身 10/10 通过。之前的 C1 测试数字为历史记录。
