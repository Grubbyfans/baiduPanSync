describe('explicit cloud EPUB inventory merge',function()
    local Inventory,Catalog,Record,Meta,json
    local function book(id,size)
        return {schemaVersion=2,status='ready',bookId=id,title=id,fileName=id..'.epub',path='books/'..id..'.epub',
            size=size or 10,uploadedAt=Record.iso_timestamp(1795000000),coverPath='covers/'..id..'.json',coverVersion='original'}
    end
    local function entry(path,size)return {path=path,size=size or 10,type='file'}end
    setup(function()require('commonrequire');Inventory=require('modules/cloud_inventory');Catalog=require('modules/library_catalog');Record=require('modules/progress_record');Meta=require('modules/book_metadata');json=require('json')end)
    it('imports actual uppercase and long legal names without downloading book metadata',function()
        local long=string.rep('书',77)..'ab'
        local merged,summary=Inventory.merge(Catalog.empty(),{entry('books/new.EPUB'),entry('books/'..long..'.epub'),entry('books/ignore.pdf')},1795000100)
        assert.is_equal(2,summary.added);assert.is_equal(0,summary.skipped)
        assert.is_equal('books/new.EPUB',Catalog.find(merged,'new').path)
        assert.is_equal('new.EPUB',Meta.filename(Catalog.find(merged,'new')))
        assert.is_equal(long..'.epub',Catalog.find(merged,long).fileName)
        assert.is_truthy(Catalog.encode(merged));assert.is_nil(Catalog.find(merged,'new').coverPath)
    end)
    it('skips invalid individual entries and reports full paths and reasons',function()
        local long='books/'..string.rep('书',84)..'.epub'
        local merged,summary=Inventory.merge(Catalog.empty(),{entry('books/good.epub'),entry(long),entry('books/bad%.epub'),
            entry('books/empty.epub',0),entry('books/huge.epub',1024*1024*1024+1)},1795000100)
        assert.is_equal(1,summary.added);assert.is_equal(4,summary.skipped);assert.is_equal(1,#merged.books)
        local text=Inventory.summary(summary);assert.is_truthy(text:find(long,1,true));assert.is_truthy(text:find('255 字节',1,true))
        assert.is_truthy(text:find('books/bad%.epub',1,true))
    end)
    it('leaves duplicate groups and old records untouched while importing unrelated books',function()
        local old=book('same');local index={schemaVersion=2,books={old}}
        local merged,summary=Inventory.merge(index,{entry('books/same.epub'),entry('books/same.EPUB'),entry('books/new.epub')},1795000100)
        assert.is_equal(2,summary.skipped);assert.is_equal(1,summary.added);assert.are.same(old,Catalog.find(merged,'same'))
        assert.is_equal(1,#index.books);assert.is_equal(2,#merged.books)
        local text=Inventory.summary(summary);assert.is_truthy(text:find('books/same.EPUB',1,true));assert.is_truthy(text:find('books/same.epub',1,true))
    end)
    it('updates changed sizes while retaining cover references and missing entries',function()
        local index={schemaVersion=2,books={book('changed'),book('missing')}}
        local merged,summary=Inventory.merge(index,{entry('books/changed.epub',20)},1795000100)
        assert.is_equal(1,summary.updated);assert.is_equal(1,summary.missing)
        assert.is_equal(20,Catalog.find(merged,'changed').size);assert.is_equal('original',Catalog.find(merged,'changed').coverVersion)
        assert.are.same(index.books[2],Catalog.find(merged,'missing'))
        assert.is_equal(10,index.books[1].size)
    end)
    it('does not mark an unchanged directory as requiring a catalog write',function()
        local index={schemaVersion=2,books={book('same')}}
        local merged,summary=Inventory.merge(index,{entry('books/same.epub')},1795000100)
        assert.is_false(summary.changed);assert.is_equal(1,summary.unchanged);assert.are.same(index,merged)
    end)
    it('does not falsely report missing when the same name moves to an uppercase extension',function()
        local index={schemaVersion=2,books={book('same')}}
        local merged,summary=Inventory.merge(index,{entry('books/same.EPUB')},1795000100)
        assert.is_equal(1,summary.updated);assert.is_equal(0,summary.missing)
        assert.is_equal('books/same.EPUB',merged.books[1].path)
    end)
    it('accepts safe exact EPUB paths but rejects escaping or identity mismatches',function()
        local b=book('safe');b.fileName='safe.EPUB';b.path='books/safe.EPUB';assert.is_truthy(Meta.validate(b))
        b.path='books/../safe.EPUB';assert.is_nil(Meta.validate(b))
        b.path='books/safe.EPUB';b.bookId='other';assert.is_nil(Meta.validate(b))
    end)
end)
