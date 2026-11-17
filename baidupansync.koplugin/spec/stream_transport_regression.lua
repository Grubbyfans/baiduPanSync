package.path='baidupansync.koplugin/?.lua;'..package.path
local raw=string.rep('stream-fixture-',20000)
local file=fixture_temp_dir..'/source.epub'
local f=assert(io.open(file,'wb'));f:write('prefix-padding'..raw..'suffix-padding');f:close()
local captured,download=false,false
package.loaded.socket={gettime=function()return 0 end}
package.loaded.ltn12={source={string=function(value)local sent=false;return function()if not sent then sent=true;return value end end end}}
package.loaded.socketutil={set_timeout=function()end,reset_timeout=function()end}
package.loaded['ffi/util']={fsyncOpenedFile=function()end}
local fake={data='longer redirect response tail',position=0,write=function(self,chunk)
    self.data=self.data:sub(1,self.position)..chunk..self.data:sub(self.position+#chunk+1)
    self.position=self.position+#chunk;return true
end,seek=function(self,whence,offset)
    if whence=='end' then self.position=#self.data else self.position=offset or 0 end
    return self.position
end,close=function()return true end}
package.loaded['ffi/posix_h']=true
package.loaded.ffi={C={fileno=function(value)return value end,ftruncate=function(value,size)
    assert(value==fake and size==0);fake.data='';return 0
end}}
package.loaded['socket.http']={request=function(req)
    if download then req.sink('ABC');return 1,200,{} end
    local chunks={}
    while true do
        local chunk,e=req.source()
        if e then return nil,e end
        if not chunk then break end
        assert(#chunk<=65536);chunks[#chunks+1]=chunk
    end
    captured=table.concat(chunks)
    assert(tonumber(req.headers['Content-Length'])==#captured)
    req.sink('{}');return 1,200,{}
end}
local Transport=require('modules/dav_transport')
local req={url='http://fixture/upload',method='POST',writing=true,upload_path=file,upload_offset=14,
    upload_size=#raw,upload_prefix='MULTIPART-START',upload_suffix='MULTIPART-END',
    expected_sha256=require('ffi/sha2').sha256(raw)}
local e,r=Transport.perform(req)
assert(not e,e and e.message)
assert(captured=='MULTIPART-START'..raw..'MULTIPART-END' and r.uploaded==#raw)
req.expected_sha256=string.rep('0',64)
e=Transport.perform(req);assert(e.code=='UNCERTAIN')
local open=io.open
io.open=function(path,mode)
    if path=='fixture-download' then assert(mode=='r+b');fake.position=0;return fake end
    return open(path,mode)
end
download=true
e,r=Transport.perform{url='http://fixture/download',method='GET',download_path='fixture-download',reset_download=true}
assert(not e and r.size==3 and fake.data=='ABC','redirect retries must truncate the existing file descriptor')
-- Older KOReader without ftruncate can download into a fresh reserved file.
package.loaded.ffi={C={}}
fake.data='';fake.position=0
e,r=Transport.perform{url='http://fixture/download',method='GET',download_path='fixture-download',reset_download=true}
assert(not e and fake.data=='ABC')
-- Nonempty retries must fail explicitly, never retain a tail or reopen a path.
e=Transport.perform{url='http://fixture/download',method='GET',download_path='fixture-download',reset_download=true}
assert(e.code=='IO' and e.message:find('重置下载临时文件',1,true))
io.open=open
print('Streaming multipart framing, range hashing, byte limits and redirect truncation regressions passed')
