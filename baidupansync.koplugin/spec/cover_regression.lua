-- Isolated thumbnail bounds and cleanup regression.
package.path='baidupansync.koplugin/?.lua;'..package.path
local Cover=require('modules/book_cover')
local mime=require('mime')
local encoded='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg=='
local raw=assert(mime.unb64(encoded))
assert(Cover.decode(encoded)==raw)
assert(not Cover.decode(nil))
assert(not Cover.decode(string.rep('A',43696)))
assert(not Cover.decode('@@@@'))
assert(not Cover.png(raw:sub(1,16)..'\0\0\1\0'..raw:sub(21)))
assert(not Cover.png(raw:sub(1,20)..'\0\0\2\0'..raw:sub(25)))
assert(not Cover.png(string.rep('x',32769)))
local renderer={renderImageData=function(_,data,size)
    assert(data==raw and size==#raw);return {image=true}
end}
package.loaded['ui/renderimage']=renderer
assert(Cover.render(encoded).image)
renderer.renderImageData=function()error('bad PNG')end
assert(not Cover.render(encoded))
local freed=0
local image={getWidth=function()return 1200 end,getHeight=function()return 1600 end,
    free=function()freed=freed+1 end}
image.scale=function(_,w,h)
    assert(w<=240 and h<=320)
    return {free=function()freed=freed+1 end}
end
package.loaded['apps/filemanager/filemanagerbookinfo']={getCoverImage=function()return image end}
package.loaded['ffi/blitbuffer']={TYPE_BB8=1,new=function()
    return {blitFrom=function()end,free=function()freed=freed+1 end,
        writeToFile=function(_,path)
            local f=assert(io.open(path,'wb'));f:write(raw);f:close();return true
        end}
end}
local temp=os.tmpname()
assert(Cover.decode(Cover.extract('/book.epub',temp))==raw)
assert(freed==3 and not io.open(temp,'rb'))
image.scale=function()error('failed to scale')end
assert(not Cover.extract('/book.epub',temp))
assert(freed==4 and not io.open(temp,'rb'))
print('thumbnail size, decoding, rendering fallback and cleanup regressions passed')
