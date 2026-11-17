# 公共 CA 证书包

`ca-bundle.crt` 是 curl 从 Mozilla 信任库提取的公共根证书包，作为无法发现 KOReader/系统 CA 时的后备。它不包含私钥或用户凭据，不是百度服务端证书的固定指纹。

- 来源：[curl CA Extract](https://curl.se/docs/caextract.html)
- 下载：[cacert.pem](https://curl.se/ca/cacert.pem)
- 发布校验值：[SHA-256](https://curl.se/ca/cacert.pem.sha256)
- Mozilla 数据时间：2026-11-05；下载核对日期：2026-11-17。
- 随包 SHA-256：见 `ca-bundle.sha256`，下载时已与 curl HTTPS 发布值核对，并用 Python OpenSSL 成功加载 118 个 CA。
- 许可证：Mozilla Public License 2.0，见 `MPL-2.0.txt`。证书包原始说明保留在文件开头。

更新时从上述 HTTPS 来源取得新的证书包，核对发布校验值后替换，并更新本说明和插件版本。插件不自动通过未经验证的连接下载信任根，也不关闭证书验证。自定义私有 CA 应使用显式 CA 文件设置；错误的显式路径不会触发自动回退。
