describe('unique local book index',function()
    local Store,lfs,root,store
    local function write(path,raw)local f=assert(io.open(path,'wb'));f:write(raw or 'epub');f:close();return path end
    local function read(path)local f=assert(io.open(path,'rb'));local raw=f:read('*a');f:close();return raw end
    local function rm(path)
        local st=lfs.symlinkattributes(path);if not st then return end
        if st.mode=='directory'then for n in lfs.dir(path)do if n~='.' and n~='..'then rm(path..'/'..n)end end;lfs.rmdir(path)
        else os.remove(path)end
    end
    local function scan(opts)
        local result,e;store:scan(root..'/books',opts or {schedule=function(cb)cb()end},function(err,v)e=err;result=v end)
        return result,e
    end
    setup(function()require('commonrequire');Store=require('modules/local_books');lfs=require('libs/libkoreader-lfs')end)
    before_each(function()
        root=os.tmpname();os.remove(root);assert(lfs.mkdir(root));root=require('ffi/util').realpath(root)
        assert(lfs.mkdir(root..'/books'));assert(lfs.mkdir(root..'/books/sub'))
        store=Store:new{dir=root..'/state'}
    end)
    after_each(function()rm(root)end)
    it('persists a recursive name-only index and reloads without scanning',function()
        write(root..'/books/中文.epub');write(root..'/books/sub/other.EPUB')
        local v,e=scan();assert.is_nil(e);assert.is_truthy(v.books['中文']);assert.is_truthy(v.books.other)
        local loaded=Store:new{dir=root..'/state'}:load(root..'/books');assert.are.same(v,loaded)
        assert.is_nil(store:load(root..'/another-root'))
    end)
    it('ignores non-EPUB files even with long names or cloud-incompatible characters',function()
        local name=string.rep('书',76)..'book'
        write(root..'/books/'..name..'.pdf')
        write(root..'/books/sub/'..name..'.PDF')
        write(root..'/books/'..name..'.txt')
        write(root..'/books/percent%name.pdf')
        write(root..'/books/real.epub')
        local v,e=scan();assert.is_nil(e)
        local count=0;for _ in pairs(v.books)do count=count+1 end
        assert.is_equal(1,count);assert.is_truthy(v.books.real)
    end)
    it('indexes existing 238-byte EPUB names without cloud truncation or false errors',function()
        local id=string.rep('书',77)..'ab'
        local filename=id..'.epub';assert.is_equal(238,#filename)
        local path=write(root..'/books/'..filename)
        local v,e=scan();assert.is_nil(e);assert.is_equal(path,v.books[id].path)
        local loaded=assert(store:load(root..'/books'));assert.is_equal(path,loaded.books[id].path)
        assert.is_equal(path,store:find(root..'/books',id).path)
        assert(store:register(root..'/books',id,path))
        -- Local-only names need not satisfy cloud upload sanitization rules.
        write(root..'/books/percent%name.epub')
        v,e=scan();assert.is_nil(e);assert.is_truthy(v.books['percent%name'])
    end)
    it('reports every duplicate full path and retains the previous complete index',function()
        write(root..'/books/book.epub');assert(scan())
        local previous=read(store.file)
        write(root..'/books/sub/book.EPUB');write(root..'/books/sub/other.epub');write(root..'/books/other.epub')
        local _,e=scan();assert.is_equal('CONFLICT',e.code)
        for _,path in ipairs({'/book.epub','/sub/book.EPUB','/other.epub','/sub/other.epub'})do assert.is_truthy(e.message:find(root..'/books'..path,1,true))end
        assert.is_equal(previous,read(store.file))
        local ok,blocked=pcall(store.require_index,store,root..'/books');assert.is_false(ok);assert.is_equal('CONFLICT',blocked.code)
        os.remove(root..'/books/sub/book.EPUB');os.remove(root..'/books/sub/other.epub')
        assert(scan());assert.is_nil(lfs.attributes(store.blocked));assert(store:require_index(root..'/books'))
    end)
    it('retains previous data on cancellation and read failure',function()
        write(root..'/books/book.epub');assert(scan());local previous=read(store.file)
        local _,e=scan{is_cancelled=function()return true end};assert.is_equal('CANCELLED',e.code)
        assert.is_equal(previous,read(store.file))
        local original=lfs.dir;lfs.dir=function()error('unreadable')end
        _,e=scan();lfs.dir=original
        assert.is_equal('IO',e.code);assert.is_equal(previous,read(store.file))
    end)
    it('updates only the downloaded book and prevents registering a second same-name path',function()
        assert(scan());local first=write(root..'/books/book.epub')
        assert(store:register(root..'/books','book',first))
        local other=write(root..'/books/sub/book.epub')
        local ok,e=store:register(root..'/books','book',other);assert.is_nil(ok);assert.is_equal('CONFLICT',e.code)
        assert.is_equal(first,store:load(root..'/books').books.book.path)
    end)
    it('removes missing paths on action and deletes only the selected local EPUB',function()
        local book=write(root..'/books/book.epub');local settings=write(root..'/books/book.epub.lua','keep settings')
        assert(scan());local deleted=assert(store:delete(root..'/books','book'))
        assert.is_equal(book,deleted.path);assert.is_nil(lfs.attributes(book));assert.is_equal('keep settings',read(settings))
        assert.is_nil(store:load(root..'/books').books.book)
        write(book);assert(scan());os.remove(book)
        assert.is_nil(store:find(root..'/books','book'));assert.is_nil(store:load(root..'/books').books.book)
    end)
    it('refuses deleting an open book and never follows symbolic links',function()
        local book=write(root..'/books/book.epub');assert(scan())
        local ok,e=store:delete(root..'/books','book',book);assert.is_nil(ok);assert.is_equal('CONFLICT',e.code)
        write(root..'/outside.epub');assert(lfs.link(root..'/outside.epub',root..'/books/link.epub',true))
        local v=assert(scan());assert.is_nil(v.books.link)
        os.remove(book);assert(lfs.link(root..'/outside.epub',book,true))
        ok,e=pcall(store.find,store,root..'/books','book');assert.is_false(ok);assert.is_equal('CONFLICT',e.code)
    end)
    it('exposes the scan button and distinct local open/delete actions without auto-download',function()
        local UI=require('ui/uimanager');local CloudUI=require('ui/cloud_dialog')
        local checked,opened,deleted,downloaded=0,0,0,0
        local entry={local_path=root..'/books/book.epub',record={bookId='book',fileName='book.epub',title='book',size=123}}
        local result={entries={entry},issues={},backend='fixture',on_check_local=function()checked=checked+1 end,
            on_open_local=function(e)assert.is_equal(entry,e);opened=opened+1 end,
            on_delete_local=function(e)assert.is_equal(entry,e);deleted=deleted+1 end}
        local grid=CloudUI.library(result,function()downloaded=downloaded+1 end)
        grid:options();local menu=UI._window_stack[#UI._window_stack].widget
        for _,row in ipairs(menu.buttons)do if row[1].text=='检查本机书籍'then row[1].callback()end end
        assert.is_equal(1,checked)
        grid:select(entry);assert.is_equal(0,downloaded)
        local dialog=UI._window_stack[#UI._window_stack].widget
        assert.is_truthy(dialog.title:find(entry.local_path,1,true));assert.is_equal('重新下载',dialog.buttons[1][1].text)
        dialog.buttons[2][1].callback();assert.is_equal(1,opened)
        grid:select(entry);dialog=UI._window_stack[#UI._window_stack].widget
        dialog.buttons[3][1].callback();assert.is_equal(1,deleted);assert.is_equal(0,downloaded)
        local output=os.getenv('BPS_LOCAL_PREVIEW')
        if output then local Screen=require('device').screen;Screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE);grid:paintTo(Screen.bb,0,0);assert(Screen:shot(output))end
        UI:close(grid)
    end)
end)
