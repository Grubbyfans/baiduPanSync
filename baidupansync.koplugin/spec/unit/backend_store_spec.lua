describe('backend profile and private credentials',function()
    local Store,Config,File,lfs,json,dir,store
    setup(function()
        require('commonrequire');Store=require('modules/backend_store');Config=require('modules/config_store')
        File=require('modules/file_util');lfs=require('libs/libkoreader-lfs');json=require('json')
    end)
    before_each(function()
        dir=os.tmpname();os.remove(dir);assert(lfs.mkdir(dir))
        store=Store:new{dir=dir,config=Config:new{dir=dir}}
    end)
    after_each(function()
        for name in lfs.dir(dir) do if name~='.' and name~='..' then os.remove(dir..'/'..name) end end
        lfs.rmdir(dir)
    end)
    it('persists credentials separately and keeps identity when password changes',function()
        local p={type='webdav',root_url='http://localhost/sync/',username='u',password='secret-one'}
        assert(store:save(p))
        assert.is_equal('secret-one',store:load().password)
        assert.is_nil(File.read_file(dir..'/config.json'):find('secret-one',1,true))
        assert.is_equal('rw-------',lfs.attributes(store.file,'permissions'))
        local state=store.config:_read();local id=state.data.activeBackendId
        p.password='secret-two';assert(store:save(p))
        assert.is_equal(id,store.config:_read().data.activeBackendId)
        assert.is_equal('secret-two',store:load().password)
    end)
    it('preserves future credentials and refuses overwriting them',function()
        local f=assert(io.open(store.file,'wb'));f:write('{"schemaVersion":99,"data":{}}');f:close()
        local ok,e=store:save{type='webdav',root_url='http://localhost/',username='u',password='p'}
        assert.is_nil(ok);assert.is_equal('UNSUPPORTED',e.code)
        assert.is_truthy(File.read_file(store.file):find('99',1,true))
    end)
end)
