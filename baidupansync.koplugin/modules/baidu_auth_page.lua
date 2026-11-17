-- Self-contained mobile page. No third-party assets, no persistent browser
-- storage, no access/refresh token or app secret is ever sent to this page.
local M={}
function M.escape(s)
    return (s:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&#39;'))
end
function M.configure(path,csrf,profile)
    profile=profile or {}
    local hint=profile.has_secret and '留空保留阅读器已有密钥' or '粘贴应用 SecretKey'
    return [[<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>配置百度应用 · BaiduPanSync</title>
<style>body{font-family:system-ui,sans-serif;background:#f3f5f7;color:#18212b;margin:0;padding:24px}
main{max-width:480px;margin:4vh auto;background:white;border-radius:16px;padding:28px}h1{font-size:24px}
p{line-height:1.7}label{display:block;margin:18px 0 6px}input,button{box-sizing:border-box;width:100%;
padding:14px;font-size:16px;border:1px solid #b7c2cd;border-radius:8px}button{margin-top:22px;
background:#1c5bbb;color:white;border:0}.note{font-size:14px;color:#56616f}#status{white-space:pre-wrap}</style>
<main><h1>配置百度网盘应用</h1><p>在手机粘贴应用资料，保存后继续百度授权。无需在阅读器输入长密钥。</p>
<form id="form" method="post" action="]]..M.escape(path)..[[/config" autocomplete="off">
<label for="app_key">AppKey / API Key</label><input id="app_key" name="app_key" maxlength="256"
required autocapitalize="off" spellcheck="false" value="]]..M.escape(profile.app_key or '')..[[">
<label for="secret_key">SecretKey</label><input id="secret_key" name="secret_key" type="password"
maxlength="512" autocomplete="new-password" autocapitalize="off" spellcheck="false" placeholder="]]..
        M.escape(hint)..[[">
<label for="app_dir">实际应用目录</label><input id="app_dir" name="app_dir" maxlength="1024"
required spellcheck="false" placeholder="/apps/你的应用名称" value="]]..M.escape(profile.app_dir or '')..[[">
<input type="hidden" name="csrf" value="]]..M.escape(csrf)..[[">
<button id="submit">保存并继续授权</button></form><p id="status" role="status"></p>
<p class="note">本页通过局域网 HTTP 提交应用密钥，不加密，请仅在可信 Wi-Fi 使用。
已有 SecretKey 不会返回手机，不会写入网址；本页不会主动保存密钥到浏览器。不要填写百度账号密码。
阅读器 IP 与 CA 文件仍可在阅读器的“应用配置”中设置。</p></main><script>
const form=document.getElementById('form'),status=document.getElementById('status'),button=document.getElementById('submit');
form.addEventListener('submit',async e=>{e.preventDefault();button.disabled=true;
try{const response=await fetch(form.action,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
body:new URLSearchParams(new FormData(form)),cache:'no-store'});document.getElementById('secret_key').value='';
status.textContent=await response.text();if(response.ok||response.status===409){location.replace(location.pathname);}else{button.disabled=false;}}
catch(_){document.getElementById('secret_key').value='';button.disabled=false;
status.textContent='连接失败，请检查 Wi-Fi，或在阅读器重新开始。';}});
</script></html>]]
end
function M.render(url,path,csrf)
    return [[<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>连接百度网盘 · BaiduPanSync</title>
<style>body{font-family:system-ui,sans-serif;background:#f3f5f7;color:#18212b;margin:0;padding:24px}
main{max-width:480px;margin:5vh auto;background:white;border-radius:16px;padding:28px}
h1{font-size:24px}p{line-height:1.7}.note{color:#56616f;font-size:14px}a,button{display:block;
box-sizing:border-box;text-align:center;background:#1c5bbb;color:white;border:0;border-radius:8px;
padding:14px;font-size:16px;text-decoration:none;width:100%}textarea{box-sizing:border-box;width:100%;
font:16px system-ui;min-height:110px;padding:12px;margin:10px 0}#status{white-space:pre-wrap}</style>
<main><h1>连接百度网盘</h1><p>1. 前往百度完成授权，然后复制授权码。<br>
2. 返回本页，粘贴授权码并提交。</p><a target="_blank" rel="noopener noreferrer" href="]]..
        M.escape(url)..[[">前往百度授权 ↗</a><form id="form" method="post" action="]]..
        M.escape(path)..[["><label for="code"><p>百度授权码</p></label>
<textarea id="code" name="code" maxlength="1024" required autocomplete="off" autocapitalize="off"
spellcheck="false" placeholder="只粘贴授权码，无需输入百度密码"></textarea>
<input type="hidden" name="csrf" value="]]..M.escape(csrf)..[[">
<button id="submit">提交并连接</button></form><p id="status" role="status"></p>
<p class="note">请保持阅读器联网并停留在授权页面。本页仅在本次授权期间有效。
局域网 HTTP 不加密，只应在可信 Wi-Fi 使用；请勿转发页面地址或授权码。
访问凭据只保存在阅读器，不返回手机。</p></main><script>
const form=document.getElementById('form'),status=document.getElementById('status');
form.addEventListener('submit',async e=>{e.preventDefault();document.getElementById('submit').disabled=true;
try{const response=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':
'application/x-www-form-urlencoded'},body:new URLSearchParams(new FormData(form)),cache:'no-store'});
const message=await response.text();document.getElementById('code').value='';status.textContent=message;
if(response.status!==202){document.getElementById('submit').disabled=false;return;}
const timer=setInterval(async()=>{try{const r=await fetch(location.pathname+'/status',{cache:'no-store'});
const s=await r.text();status.textContent=s;if(s!=='正在校验并保存，请稍候…'){clearInterval(timer);}}
catch(_){clearInterval(timer);status.textContent='服务已关闭，请在阅读器查看授权结果。';}},1000);
}catch(_){status.textContent='连接失败，请检查 Wi-Fi 并在阅读器重新开始授权。';}});
</script></html>]]
end
return M
