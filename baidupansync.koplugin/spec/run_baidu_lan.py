"""Exercise the production Lua HTTP parser/poll loop with real local sockets.

Requires lupa; uses fixture codes only. Binds one local private IPv4 address,
never a wildcard address. No request is made to Baidu or another external host.
"""
import http.client
import ipaddress
import os
from pathlib import Path
import socket
import threading
import time
from lupa import LuaRuntime

repo = Path(__file__).resolve().parents[2]
os.chdir(repo)
addresses = socket.gethostbyname_ex(socket.gethostname())[2]
address = next((v for v in addresses if ipaddress.ip_address(v).is_private and not v.startswith('127.')), None)
if address is None:
    raise RuntimeError('A local private IPv4 interface is required for the LAN regression')
lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
opened = []

def wrap(sock):
    opened.append(sock)
    table = lua.table()
    def call(fn, *args):
        try:
            value = fn(*args)
            return 1 if value is None else value
        except BlockingIOError:
            return None, b'timeout'
        except OSError:
            return None, b'closed'
    table[b'settimeout'] = lambda _, delay: call(sock.settimeout, float(delay))
    table[b'bind'] = lambda _, ip, port: call(sock.bind, (ip.decode(), int(port)))
    table[b'listen'] = lambda _, count: call(sock.listen, int(count))
    table[b'close'] = lambda _: call(sock.close)
    table[b'getsockname'] = lambda _: (sock.getsockname()[0].encode(), sock.getsockname()[1])
    def accept(_):
        try:
            child, _peer = sock.accept()
            return wrap(child)
        except BlockingIOError:
            return None
    table[b'accept'] = accept
    def receive(_, count):
        try:
            data = sock.recv(int(count))
            if not data:
                return None, b'closed', b''
            return (data, None, None) if len(data) == count else (None, b'timeout', data)
        except BlockingIOError:
            return None, b'timeout', b''
        except OSError:
            return None, b'closed', b''
    table[b'receive'] = receive
    def send(_, data, start):
        try:
            return int(start) - 1 + sock.send(data[int(start) - 1:])
        except BlockingIOError:
            return None, b'timeout', int(start) - 1
        except OSError:
            return None, b'closed', int(start) - 1
    table[b'send'] = send
    return table

lua.globals()[b'fixture_tcp'] = lambda: wrap(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
lua.globals()[b'fixture_ip'] = address.encode()
lua.execute(b"""
package.path='baidupansync.koplugin/?.lua;'..package.path
package.loaded['modules/baidu_auth']={authorization_url=function()return 'https://openapi.baidu.com/fixture' end}
fixture_now=1000;fixture_submissions=0
receiver=assert(require('modules/baidu_auth_server').start{
    ip=fixture_ip,app_key='fixture',socket={tcp=fixture_tcp,gettime=function()return fixture_now end},
    random=function(n)return string.rep('b',n*2)end,on_code=function(code,done)
        assert(code=='fixture-code');fixture_submissions=fixture_submissions+1;done(nil)
    end})
""")
receiver = lua.globals()[b'receiver']
path = receiver[b'path'].decode()
csrf = receiver[b'csrf'].decode()
port = int(receiver[b'authority'].decode().rsplit(':', 1)[1])
results = []
failures = []

def phone():
    try:
        def request(method, target, body=None, headers=None):
            conn = http.client.HTTPConnection(address, port, timeout=5)
            try:
                conn.request(method, target, body=body, headers=headers or {})
                response = conn.getresponse()
                return response.status, response.read(), response.getheaders()
            finally:
                conn.close()
        status, body, headers = request('GET', path)
        assert status == 200 and '前往百度授权'.encode() in body
        assert dict(headers)['Cache-Control'] == 'no-store'
        assert request('GET', '/wrong')[0] == 404
        assert request('POST', path, 'code=fixture-code&csrf=bad',
                       {'Content-Type': 'application/x-www-form-urlencoded'})[0] == 400
        status, _, _ = request('POST', path, f'code=fixture-code&csrf={csrf}',
                               {'Content-Type': 'application/x-www-form-urlencoded'})
        assert status == 202
        status, body, _ = request('GET', path + '/status')
        assert status == 200 and '授权成功'.encode() in body
        assert request('POST', path, f'code=fixture-code&csrf={csrf}',
                       {'Content-Type': 'application/x-www-form-urlencoded'})[0] == 409
        results.append(True)
    except BaseException as error:
        failures.append(error)

worker = threading.Thread(target=phone, daemon=True)
try:
    worker.start()
    deadline = time.monotonic() + 12
    while worker.is_alive() and time.monotonic() < deadline:
        receiver[b'poll_once'](receiver)
        time.sleep(0.005)
    worker.join(timeout=0.1)
    if failures:
        raise failures[0]
    assert results and lua.globals()[b'fixture_submissions'] == 1
    lua.globals()[b'fixture_now'] = 1006
    receiver[b'poll_once'](receiver)
    assert receiver[b'closed']
    probe = socket.socket()
    probe.settimeout(0.2)
    try:
        assert probe.connect_ex((address, port)) != 0
    finally:
        probe.close()
    print('Real LAN sockets: mobile page, code submit, status, replay and listener shutdown passed')
finally:
    receiver[b'stop'](receiver, b'test_cleanup')
    for sock in opened:
        sock.close()
