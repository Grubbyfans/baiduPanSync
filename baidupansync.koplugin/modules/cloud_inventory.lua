-- Merge explicit books/ enumeration without fetching any EPUB or sidecar.
local Name=require('modules/book_name')
local Catalog=require('modules/library_catalog')
local Record=require('modules/progress_record')
local json=require('json')
local M={}
function M.merge(index,entries,now)
    -- Never mutate the old snapshot until the whole enumeration has succeeded.
    local merged=json.decode(assert(Catalog.encode(index)))
    local by_id,positions={},{}
    for i,book in ipairs(merged.books)do by_id[book.bookId]=book;positions[book.bookId]=i end
    local summary={added=0,updated=0,skipped=0,missing=0,unchanged=0,issues={},changed=false}
    local groups,present,blocked={},{},{}
    local function issue(path,message)
        summary.issues[#summary.issues+1]={path=path,message=message}
    end
    for _,entry in ipairs(entries)do
        present[entry.path]=entry.type=='file'
        local filename=type(entry.path)=='string' and entry.path:match('^books/([^/]+)$')
        if entry.type=='file' and filename and filename:match('%.[Ee][Pp][Uu][Bb]$') then
            local raw_id=filename:sub(1,-6)
            local id,e=Name.cloud_id(filename)
            if not id or type(entry.size)~='number' or entry.size<1 or entry.size%1~=0 or entry.size>1024*1024*1024 then
                summary.skipped=summary.skipped+1;blocked[raw_id]=true
                issue(entry.path,e and e.message or '文件为空、大小无效或超过插件的 1 GiB 上限')
            else
                groups[id]=groups[id] or {};groups[id][#groups[id]+1]=entry
            end
        end
    end
    local names={};for id in pairs(groups)do names[#names+1]=id end;table.sort(names)
    for _,id in ipairs(names)do
        local group=groups[id]
        if #group>1 or blocked[id] then
            summary.skipped=summary.skipped+#group
            for _,entry in ipairs(group)do issue(entry.path,'同名 EPUB 冲突，保留原列表条目；请在云端处理后再次更新')end
        else
            local entry=group[1];local previous=by_id[id]
            if previous and previous.path==entry.path and previous.size==entry.size then summary.unchanged=summary.unchanged+1
            elseif not previous and #merged.books>=Catalog.MAX_BOOKS then
                summary.skipped=summary.skipped+1;issue(entry.path,'书库列表已达到一万本上限，请整理后重试')
            else
                local book={schemaVersion=2,status='ready',bookId=id,title=id,fileName=entry.path:sub(7),path=entry.path,
                    size=entry.size,uploadedAt=Record.iso_timestamp(now)}
                if previous then book.coverPath=previous.coverPath;book.coverVersion=previous.coverVersion end
                if previous then merged.books[positions[id]]=book
                else merged.books[#merged.books+1]=book;positions[id]=#merged.books end
                by_id[id]=book
                summary[previous and 'updated' or 'added']=summary[previous and 'updated' or 'added']+1
                summary.changed=true
            end
        end
    end
    for _,book in ipairs(index.books)do
        if not present[by_id[book.bookId].path] then
            summary.missing=summary.missing+1
            issue(book.path,'列表中的 EPUB 未找到；原记录和进度保留，请核对云端文件')
        end
    end
    return merged,summary
end
function M.summary(v,root)
    local lines={string.format('新增 %d 本 · 更新 %d 本 · 未变化 %d 本',v.added,v.updated,v.unchanged),
        string.format('跳过 %d 项 · 缺失 %d 本',v.skipped,v.missing),'未修改云端文件名，原有阅读进度保留。'}
    for _,issue in ipairs(v.issues)do
        local path=root and (root:gsub('/+$','')..'/'..issue.path) or issue.path
        lines[#lines+1]='\n'..path..'\n原因：'..issue.message
    end
    return table.concat(lines,'\n')
end
return M
