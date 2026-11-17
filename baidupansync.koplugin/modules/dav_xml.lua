-- Restricted DAV XML reader: no DTD, external entities or recovery parsing.
local M = {}
local function decode(s)
    local bad = false
    if s:gsub("&[^;]+;", ""):find("&", 1, true) then return nil end
    s = s:gsub('&([^;]+);', function(e)
        local entities = { amp='&', lt='<', gt='>', quot='"', apos="'" }
        if not entities[e] then bad = true; return '' end
        return entities[e]
    end)
    if bad then return nil end
    return s
end
function M.parse(xml)
    if type(xml) ~= 'string' or #xml > 1024*1024 or xml:find('<!') then return nil end
    xml = xml:gsub('^%s*<%?xml.-%?>', '')
    local stack, root, cursor = {}, nil, 1
    while cursor <= #xml do
        local a,b,tag = xml:find('<([^>]+)>', cursor)
        local text = xml:sub(cursor, a and a-1 or #xml)
        local decoded = decode(text)
        if not decoded then return nil end
        if #stack > 0 then
            stack[#stack].text = stack[#stack].text .. decoded
        elseif text:find('%S') then return nil end
        if not a then break end
        if tag:sub(1,1) == '/' then
            local name = tag:match('^/([%w_:.-]+)%s*$')
            if not name or not stack[#stack] or stack[#stack].raw ~= name then return nil end
            table.remove(stack)
        else
            local name = tag:match('^([%w_:.-]+)')
            if not name then return nil end
            local ns={}
            if stack[#stack] then
                for k,v in pairs(stack[#stack].namespaces) do ns[k]=v end
            end
            local attributes=tag:sub(#name+1):gsub('/%s*$','')
            while attributes:find('%S') do
                local key,value,rest=attributes:match('^%s+([%w_:.-]+)%s*=%s*"([^"<>]*)"(.*)$')
                if not key then
                    key,value,rest=attributes:match("^%s+([%w_:.-]+)%s*=%s*'([^'<>]*)'(.*)$")
                end
                if not key then return nil end
                value=decode(value);if not value then return nil end
                if key=='xmlns' then ns['']=value end
                local prefix=key:match('^xmlns:(.+)$')
                if prefix then ns[prefix]=value end
                attributes=rest
            end
            local prefix=name:match('^([^:]+):') or ''
            if prefix~='' and not ns[prefix] then return nil end
            local node = { raw=name, name=name:match('([^:]+)$'), children={}, text='',
                namespace=ns[prefix],namespaces=ns }
            if #stack > 0 then table.insert(stack[#stack].children,node)
            elseif root then return nil else root=node end
            if not tag:match('/%s*$') then
                stack[#stack+1]=node
                if #stack > 32 then return nil end
            end
        end
        cursor=b+1
    end
    if #stack ~= 0 or not root then return nil end
    return root
end
function M.child(node, name)
    for _,v in ipairs(node.children) do if v.name == name and v.namespace=='DAV:' then return v end end
end
return M
