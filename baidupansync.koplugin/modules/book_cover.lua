-- Optional bounded PNG thumbnail, embedded in the existing publication JSON.
-- No separate network request or full EPUB download is needed to browse covers.
local M={MAX_BYTES=32768,MAX_WIDTH=240,MAX_HEIGHT=320}
local signature='\137PNG\r\n\26\n'
local function uint32(s,i)
    local a,b,c,d=s:byte(i,i+3)
    return ((a*256+b)*256+c)*256+d
end
function M.png(raw)
    if type(raw)~='string' or #raw<33 or #raw>M.MAX_BYTES
        or raw:sub(1,8)~=signature or raw:sub(9,16)~='\0\0\0\13IHDR' then return nil end
    local w,h=uint32(raw,17),uint32(raw,21)
    if w<1 or h<1 or w>M.MAX_WIDTH or h>M.MAX_HEIGHT then return nil end
    return raw
end
function M.decode(encoded)
    if type(encoded)~='string' or #encoded>43692 or #encoded%4~=0
        or encoded:find('[^A-Za-z0-9+/=]') then return nil end
    local ok,raw=pcall(require('mime').unb64,encoded)
    return ok and M.png(raw) or nil
end
function M.render(encoded)
    local raw=M.decode(encoded)
    if not raw then return nil end
    local renderer=require('ui/renderimage')
    local ok,bb=pcall(renderer.renderImageData,renderer,raw,#raw,false)
    return ok and bb or nil
end
function M.extract(path,temp)
    local original,scaled,gray
    local ok,result=pcall(function()
        local info=require('apps/filemanager/filemanagerbookinfo')
        original=info:getCoverImage(nil,path)
        if not original then return nil end
        local w,h=original:getWidth(),original:getHeight()
        if w<1 or h<1 then return nil end
        local BB=require('ffi/blitbuffer')
        for _,bound in ipairs({240,180,120,80}) do
            local factor=math.min(bound/w,(bound*4/3)/h,1)
            local tw,th=math.max(1,math.floor(w*factor)),math.max(1,math.floor(h*factor))
            scaled=original:scale(tw,th)
            gray=BB.new(tw,th,BB.TYPE_BB8);gray:blitFrom(scaled)
            local wrote=gray:writeToFile(temp,'png')
            gray:free();gray=nil;scaled:free();scaled=nil
            if wrote then
                local f=io.open(temp,'rb')
                if f then
                    local raw=f:read(M.MAX_BYTES+1);f:close()
                    if M.png(raw) then return (require('mime').b64(raw)) end
                end
            end
        end
    end)
    for _,bb in pairs({original,scaled,gray}) do pcall(bb.free,bb) end
    os.remove(temp)
    return ok and result or nil
end
return M
