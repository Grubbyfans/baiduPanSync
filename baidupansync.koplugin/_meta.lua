local _ = require("gettext")
return {
    fullname = _("BaiduPanSync"),
    description = _([[Manually synchronize EPUB books and reading progress through WebDAV or Baidu Netdisk. Includes full-content SHA-256 verification, conflict confirmation, a cached cover library, unpublished book recovery, safe downloads and Baidu OOB authorization over a temporary LAN page.]]),
    version = "0.9.8",
}
