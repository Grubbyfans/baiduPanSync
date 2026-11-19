describe('persistent daily library and thumbnail cache',function()
    local Cache,Catalog,lfs,root,backend,book,result
    local function rm(path)
        local st=lfs.symlinkattributes(path);if not st then return end
        if st.mode=='directory' then for n in lfs.dir(path)do if n~='.' and n~='..'then rm(path..'/'..n)end end;lfs.rmdir(path)
        else os.remove(path)end
    end
    setup(function()require('commonrequire');Cache=require('modules/library_cache');Catalog=require('modules/library_catalog');lfs=require('libs/libkoreader-lfs')end)
    before_each(function()
        root=os.tmpname();os.remove(root);assert(lfs.mkdir(root));backend=string.rep('a',64)
        book={schemaVersion=2,status='ready',bookId='中文书名',title='中文书名',fileName='中文书名.epub',
            path='books/中文书名.epub',size=123,uploadedAt='2026-11-19T12:00:00+08:00',coverPath='covers/中文书名.json',coverVersion='v1'}
        result={backend_id=backend,updated_at=os.time(),catalog={schemaVersion=2,books={book}}}
    end)
    after_each(function()rm(root)end)
    it('persists the lightweight catalog and checks calendar day, not elapsed 24 hours',function()
        local cache=Cache:new(root);assert(cache:save(backend,result))
        local loaded=Cache:new(root):load(backend,'webdav');assert.is_equal('中文书名',loaded.entries[1].record.bookId)
        assert.is_true(cache:fresh(loaded,result.updated_at))
        local endofday=os.time{year=2026,month=11,day=19,hour=23,min=59,sec=59}
        loaded.updated_at=endofday
        assert.is_false(cache:fresh(loaded,endofday+2))
        assert.is_nil(cache:load(string.rep('b',64),'another account'))
    end)
    it('retains thumbnails across instances and invalidates only the changed cover version',function()
        local cover='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg=='
        local cache=Cache:new(root);assert(cache:save_cover(backend,book,cover))
        assert.is_equal(cover,Cache:new(root):load_cover(backend,book))
        book.coverVersion='v2';assert.is_nil(cache:load_cover(backend,book))
        assert.is_nil(cache:load_cover(string.rep('b',64),book))
        assert(cache:save_cover(backend,book,cover));assert.is_equal(cover,cache:load_cover(backend,book))
    end)
    it('rejects duplicate names, escaping paths, inline cover data and non-array books',function()
        assert.is_truthy(Catalog.encode(result.catalog))
        result.catalog.books[2]=book;assert.is_nil(Catalog.encode(result.catalog));result.catalog.books[2]=nil
        book.path='../secret';assert.is_nil(Catalog.encode(result.catalog));book.path='books/中文书名.epub'
        book.coverPng='inline';assert.is_nil(Catalog.encode(result.catalog));book.coverPng=nil
        assert.is_nil(Catalog.decode('{"schemaVersion":2,"books":{"foo":{}}}'))
    end)
end)
