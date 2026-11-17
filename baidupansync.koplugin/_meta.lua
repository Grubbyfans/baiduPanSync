local _ = require("gettext")
return {
    fullname = _("BaiduPanSync"),
    description = _([[Manually synchronize EPUB books and reading progress through WebDAV or Baidu Netdisk. Includes full-content SHA-256 verification, conflict confirmation, a cover library, safe downloads and Baidu OOB authorization over a temporary LAN page. Baidu requires live account and device acceptance.]]),
    version = "0.8.4",
}
