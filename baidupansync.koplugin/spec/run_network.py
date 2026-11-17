#!/usr/bin/env python3
"""Run all specs with disposable localhost HTTP/TLS fixtures, then clean up."""
import json
import os
import pathlib
import subprocess
import sys
root = pathlib.Path(__file__).resolve().parent
processes = []
try:
    env = os.environ.copy()
    for name in ('dav_server.py', 'dav_tls_server.py'):
        if name == 'dav_server.py' and env.get('BPS_DAV_TEST_URL'): continue
        if name == 'dav_tls_server.py' and env.get('BPS_TLS_TEST_CONFIG'): continue
        p = subprocess.Popen([sys.executable, str(root/'fixtures'/name)], stdout=subprocess.PIPE, text=True)
        processes.append(p)
        line = p.stdout.readline().strip()
        if not line: raise RuntimeError(name+' failed to start')
        if name == 'dav_server.py': env['BPS_DAV_TEST_URL'] = 'http://127.0.0.1:'+str(int(line))+'/sync/'
        else:
            json.loads(line)
            env['BPS_TLS_TEST_CONFIG'] = line
    result = subprocess.run([str(root/'run.sh'), *sys.argv[1:]], env=env)
    raise SystemExit(result.returncode)
finally:
    for p in processes:
        p.terminate()
    for p in processes:
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
