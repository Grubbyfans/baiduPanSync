"""Run isolated Lua regressions without a KOReader build (requires lupa)."""
import base64
import hashlib
import json
import os
import tempfile
from pathlib import Path
from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[2]
os.chdir(repo)
for path in sorted((repo / 'baidupansync.koplugin/spec').glob('*regression.lua')):
    lua = LuaRuntime(encoding=None)
    lua.globals()[b'fixture_b64'] = base64.b64encode
    lua.globals()[b'fixture_unb64'] = base64.b64decode
    def from_lua(value):
        if isinstance(value, bytes):
            return value.decode('utf-8')
        if hasattr(value, 'items'):
            items = dict(value.items())
            if items and set(items) == set(range(1, len(items) + 1)):
                return [from_lua(items[i]) for i in range(1, len(items) + 1)]
            return {from_lua(k): from_lua(v) for k, v in items.items()}
        return value
    def to_lua(value):
        if isinstance(value, str):
            return value.encode('utf-8')
        if isinstance(value, (list, dict)):
            source = dict(enumerate(value, 1)) if isinstance(value, list) else value
            return lua.table_from({to_lua(k): to_lua(v) for k, v in source.items()})
        return value
    lua.globals()[b'fixture_json_encode'] = lambda v: json.dumps(from_lua(v), ensure_ascii=False, separators=(',', ':')).encode()
    lua.globals()[b'fixture_json_decode'] = lambda v: to_lua(json.loads(v))
    lua.globals()[b'fixture_sha256'] = lambda v: hashlib.sha256(v).hexdigest().encode()
    lua.globals()[b'fixture_md5'] = lambda v: hashlib.md5(v).hexdigest().encode()
    def attributes(raw_path):
        target = Path(os.fsdecode(raw_path))
        if not target.exists() and not target.is_symlink():
            return None
        return lua.table_from({b'mode': b'link' if target.is_symlink() else b'directory' if target.is_dir() else b'file',
                               b'size': target.lstat().st_size})
    lua.globals()[b'fixture_attributes'] = attributes
    lua.globals()[b'fixture_mkdir'] = lambda v: (Path(os.fsdecode(v)).mkdir(), True)[1]
    # KOReader uses POSIX rename replacement; Windows CRT rename won't replace
    # an existing file. os.replace supplies those semantics for isolated tests.
    lua.globals()[b'fixture_replace'] = lambda source, target: (os.replace(os.fsdecode(source), os.fsdecode(target)), True)[1]
    lua.execute(b"package.preload.mime=function()return {b64=fixture_b64,unb64=fixture_unb64}end")
    lua.execute(b"unpack=unpack or table.unpack; package.preload.json=function()return {encode=fixture_json_encode,decode=fixture_json_decode}end")
    lua.execute(b"package.preload['ffi/sha2']=function()return {sha256=fixture_sha256,md5=fixture_md5}end")
    lua.execute(b'os.rename=fixture_replace')
    with tempfile.TemporaryDirectory(prefix='bps-isolated-') as temporary:
        lua.globals()[b'fixture_temp_dir'] = temporary.replace('\\', '/').encode()
        lua.execute(path.read_bytes())
lua = LuaRuntime(encoding=None)
check = lua.eval(b'function(s) assert(load(s)) end')
for path in (repo / 'baidupansync.koplugin').rglob('*.lua'):
    check(path.read_bytes())
print('All isolated regressions and Lua syntax checks passed')
