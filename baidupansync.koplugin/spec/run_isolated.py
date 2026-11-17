"""Run isolated Lua regressions without a KOReader build (requires lupa)."""
import base64
import os
from pathlib import Path
from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[2]
os.chdir(repo)
for path in sorted((repo / 'baidupansync.koplugin/spec').glob('*regression.lua')):
    lua = LuaRuntime(encoding=None)
    lua.globals()[b'fixture_b64'] = base64.b64encode
    lua.globals()[b'fixture_unb64'] = base64.b64decode
    lua.execute(b"package.preload.mime=function()return {b64=fixture_b64,unb64=fixture_unb64}end")
    lua.execute(path.read_bytes())
lua = LuaRuntime(encoding=None)
check = lua.eval(b'function(s) assert(load(s)) end')
for path in (repo / 'baidupansync.koplugin').rglob('*.lua'):
    check(path.read_bytes())
print('All isolated regressions and Lua syntax checks passed')
