local _ = require("gettext")
return {
    fullname = _("BaiduPanSync"),
    description = _([[Manually synchronize EPUB books and reading progress through a self-hosted WebDAV server or Baidu Netdisk. Stage B adds full-content SHA-256 identity, cloud progress JSON and manual cross-device exchange; no network backend yet.]]),
    version = "0.2.0",
}
