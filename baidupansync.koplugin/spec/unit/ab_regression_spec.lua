describe('A/B context and recovery regressions',function()
    local Progress,Fake,Event,Hash,lfs
    local path,ui,service,queue,rp
    setup(function()
        require('commonrequire')
        Progress=require('modules/progress');Fake=require('spec/fixtures/fake_reader')
        Event=require('ui/event');Hash=require('modules/hash');lfs=require('libs/libkoreader-lfs')
    end)
    before_each(function()
        path=os.tmpname();local f=assert(io.open(path,'wb'));f:write('first epub');f:close()
        ui=Fake.new{file=path,current_page=1}
        queue={};rp=nil
        service=Progress:new{reader_ui=ui,event=Event,
            schedule=function(_,fn) queue[#queue+1]=fn end,now_ms=function()return 0 end,
            store={save_restore_point=function(_,value)rp=value;return true end,
                get_restore_point=function()return rp end,clear_restore_point=function()rp=nil;return true end}}
    end)
    after_each(function()os.remove(path)end)
    it('waits for a later tick before accepting engine arrival',function()
        local calls=0
        service:apply(service:capture(),{type='xpointer',value=Fake.target_xpointer(2)},function(e)
            assert.is_nil(e);calls=calls+1
        end)
        assert.is_equal(0,calls)
        table.remove(queue,1)()
        assert.is_equal(1,calls)
    end)
    it('rejects replacing the reader document with the same path',function()
        local context=service:capture()
        ui.document=Fake.new{file=path}.document
        local ok,e=service:_check_context(context)
        assert.is_nil(ok);assert.is_equal('CONFLICT',e.code)
    end)
    it('rejects mtime changes even when size and path match',function()
        local context=service:capture()
        assert(lfs.touch(path,context.book.mtime+10,context.book.mtime+10))
        local ok,e=service:_check_context(context)
        assert.is_nil(ok);assert.is_equal('CONFLICT',e.code)
    end)
    it('does not accept merely sharing a page in scroll mode',function()
        ui.rolling.view.view_mode='scroll'
        assert.is_false(service:_match_location(Fake.page_start_xpointer(2),Fake.target_xpointer(2),2))
    end)
    it('rejects legacy recovery and mismatched full identity before undo',function()
        rp={book={file_path=path,size=10},position={type='xpointer',value=Fake.target_xpointer(2)}}
        service.identity={identify=function(_,_,_,done)done(nil,{content_sha256=Hash.sha256_text('different')})end}
        local e
        service:undo(function(err)e=err end)
        assert.is_equal('UNSUPPORTED',e.code)
        rp.book.content_sha256=Hash.sha256_text('original')
        service:undo(function(err)e=err end)
        assert.is_equal('CONFLICT',e.code)
        assert.is_equal(0,ui.document.jump_count)
    end)
end)
