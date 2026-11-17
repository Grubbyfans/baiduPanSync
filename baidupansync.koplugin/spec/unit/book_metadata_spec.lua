describe('published book metadata protocol',function()
    local Meta,Hash,json
    local function valid()
        local id=Hash.sha256_text('EPUB')
        return {schemaVersion=1,status='ready',bookId=id,contentSha256=id,path='books/'..id..'.epub',size=4,
            title='title',fileName='book.epub',uploadedAt='2026-11-17T12:00:00+08:00',verificationLevel='size'}
    end
    setup(function()require('commonrequire');Meta=require('modules/book_metadata');Hash=require('modules/hash');json=require('json')end)
    it('accepts valid metadata and uses a display name without changing content identity',function()
        local v=valid();v.displayFileName='renamed.epub'
        local decoded=assert(Meta.decode(assert(Meta.encode(v))))
        assert.is_equal(v.bookId,decoded.bookId);assert.is_equal('renamed.epub',Meta.filename(decoded))
    end)
    it('rejects mismatched digest, path, size and verification strength',function()
        for key,value in pairs({contentSha256=string.rep('f',64),path='../book.epub',size=-1,verificationLevel='etag'})do
            local v=valid();v[key]=value;assert.is_nil(Meta.validate(v))
        end
    end)
    it('rejects unknown versions, oversized JSON, malformed JSON and invalid device times',function()
        local v=valid();v.schemaVersion=99
        local value,e=Meta.decode(json.encode(v));assert.is_nil(value);assert.is_equal('UNSUPPORTED',e.code)
        assert.is_nil(Meta.decode(string.rep(' ',65537)));assert.is_nil(Meta.decode('{'))
        v=valid();v.uploadedAt='2026-99-17T12:00:00+08:00';assert.is_nil(Meta.validate(v))
    end)
    it('keeps paths in filenames from escaping the download directory',function()
        assert.is_equal('book.epub',Meta.name('../book.epub'))
        assert.is_equal('book.epub',Meta.name('C:\\book.epub'))
        assert.is_nil(Meta.name('..'));assert.is_nil(Meta.name('bad\0.epub'))
        assert.is_equal('epub.epub',Meta.name('epub'))
    end)
    it('truncates long UTF-8 names without splitting a character',function()
        local name=Meta.name(string.rep('书',160)..'.epub')
        assert.is_true(#name<=255);assert.is_true(require('modules/progress_record').is_valid_utf8(name))
        assert.is_truthy(name:match('%.epub$'))
    end)
end)
