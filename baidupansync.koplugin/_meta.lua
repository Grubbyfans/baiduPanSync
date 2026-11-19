local _ = require("gettext")
return {
    fullname = _("BaiduPanSync"),
    description = _([[Manually synchronize EPUB books by filename through WebDAV or Baidu Netdisk. Uses a single library catalog, daily local library caching, persistent thumbnails, seven-hour Baidu download links and same-name replacement with reading progress retained.]]),
    version = "0.10.9",
}
