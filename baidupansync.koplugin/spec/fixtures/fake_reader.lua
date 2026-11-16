--[[--
Deterministic fake of the small part of ReaderUI used by ProgressService.

The fake models crengine's page-mode behaviour that matters for verification:
- an XPointer can point inside a page, while after the jump the engine reports
  the XPointer of the page start (canonicalization), so exact string equality is
  not enough;
- Rolling's cached xpointer is updated eagerly, which must never be trusted as
  proof of the jump;
- selected target pages can be made unreachable to exercise failure/rollback.
]]

local FakeReader = {}

local function page_start_xpointer(page)
    return string.format("/body/DocFragment[1]/body/div/p[%d]/text().0", page)
end

local function target_xpointer(page, offset)
    return string.format("/body/DocFragment[1]/body/div/p[%d]/text().%d", page, offset or 5)
end

local function page_from_xpointer(xpointer)
    if type(xpointer) ~= "string" then return nil end
    local page = xpointer:match("/p%[(%d+)%]")
    page = tonumber(page)
    if page and page > 0 then return page end
    return nil
end

function FakeReader.new(opts)
    opts = opts or {}

    local doc = {
        file = opts.file,
        info = { has_pages = opts.has_pages or false },
        _format = opts.format or "epub",
        _current_page = opts.current_page or 1,
        _current_xpointer = nil,
        _exact = opts.exact or false,
        _fail_pages = opts.fail_pages or {},
        jump_count = 0,
    }
    doc._current_xpointer = page_start_xpointer(doc._current_page)

    function doc:getDocumentFormat()
        return self._format
    end

    function doc:getPageFromXPointer(xpointer)
        return page_from_xpointer(xpointer)
    end

    function doc:getXPointer()
        return self._current_xpointer
    end

    function doc:gotoXPointer(xpointer)
        local page = page_from_xpointer(xpointer)
        if not page then return false end
        self.jump_count = self.jump_count + 1
        if self._fail_pages[page] then return false end
        self._current_page = page
        self._current_xpointer = self._exact and xpointer or page_start_xpointer(page)
        if self.rolling then
            self.rolling.xpointer = xpointer
        end
        return true
    end

    function doc:forcePage(page, offset)
        self._current_page = page
        self._current_xpointer = page_start_xpointer(page)
        if self.rolling then
            self.rolling.xpointer = target_xpointer(page, offset or 1)
        end
    end

    function doc:currentPage()
        return self._current_page
    end

    local rolling = {
        xpointer = opts.rolling_xpointer or target_xpointer(doc._current_page, 5),
        percent = opts.percent,
        view = { view_mode = opts.view_mode or "page" },
    }
    function rolling:getLastProgress()
        return self.xpointer
    end
    function rolling:getLastPercent()
        return self.percent
    end

    doc.rolling = rolling

    local ui = {
        document = doc,
        rolling = rolling,
        doc_props = opts.title and { display_title = opts.title } or nil,
        doc_settings = {
            readSetting = function(_, key)
                if key == "partial_md5_checksum" then return opts.partial_md5 end
                return nil
            end,
        },
    }

    function ui:handleEvent(event)
        if event.handler == "onGotoXPointer" then
            return self.document:gotoXPointer(event.args[1])
        end
        return false
    end

    return ui
end

FakeReader.page_start_xpointer = page_start_xpointer
FakeReader.target_xpointer = target_xpointer
FakeReader.page_from_xpointer = page_from_xpointer

return FakeReader
