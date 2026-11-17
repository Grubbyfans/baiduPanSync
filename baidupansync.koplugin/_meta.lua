local _ = require("gettext")
return {
    fullname = _("BaiduPanSync"),
    description = _([[Manually synchronize EPUB books and reading progress through WebDAV. Includes full-content SHA-256 verification, conflict confirmation, a cloud library, safe downloads. Includes Baidu OOB authorization over a temporary LAN page and isolated C2 API tests; Baidu book/progress operations await acceptance.]]),
    version = "0.7.1",
}
