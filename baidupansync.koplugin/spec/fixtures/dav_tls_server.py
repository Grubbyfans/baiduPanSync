"""Local TLS certificate matrix. Needs openssl, uses only temporary test keys."""
import http.server
import json
import pathlib
import signal
import ssl
import subprocess
import tempfile
import threading
import sys
sys.dont_write_bytecode = True
from dav_server import Handler

def command(*args):
    subprocess.run(['openssl', *map(str,args)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

def stop(*_): raise KeyboardInterrupt
signal.signal(signal.SIGTERM,stop)
with tempfile.TemporaryDirectory(prefix='bps-tls-') as directory:
    root=pathlib.Path(directory)
    command('req','-x509','-newkey','rsa:2048','-nodes','-keyout',root/'ca.key','-out',root/'ca.pem',
            '-subj','/CN=BPS Test CA','-days','2','-addext','basicConstraints=critical,CA:TRUE')
    (root/'index.txt').write_text('')
    (root/'serial').write_text('1000')
    (root/'ca.cnf').write_text(f'[ca]\ndefault_ca=local\n[local]\ndatabase={root}/index.txt\nnew_certs_dir={root}\ncertificate={root}/ca.pem\nprivate_key={root}/ca.key\nserial={root}/serial\ndefault_md=sha256\npolicy=names\n[names]\ncommonName=supplied\n')
    command('req','-x509','-newkey','rsa:2048','-nodes','-keyout',root/'other.key','-out',root/'other.pem',
            '-subj','/CN=BPS Other CA','-days','2','-addext','basicConstraints=critical,CA:TRUE')
    endpoints={'cafile':str(root/'ca.pem'),'othercafile':str(root/'other.pem')}
    servers=[]
    for name,san,days in [('valid','DNS:localhost,IP:127.0.0.1',2),
                          ('wrong','DNS:wrong.invalid',2),('expired','DNS:localhost',-1)]:
        key=root/(name+'.key');csr=root/(name+'.csr');cert=root/(name+'.pem')
        ext=root/(name+'.ext');ext.write_text('[server]\nsubjectAltName='+san+'\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
        command('req','-new','-newkey','rsa:2048','-nodes','-keyout',key,'-out',csr,'-subj','/CN=localhost')
        if days < 0:
            command('ca','-batch','-config',root/'ca.cnf','-in',csr,'-out',cert,
                    '-startdate','20200101000000Z','-enddate','20210101000000Z','-extfile',ext,'-extensions','server')
        else:
            command('x509','-req','-in',csr,'-CA',root/'ca.pem','-CAkey',root/'ca.key','-CAcreateserial',
                    '-out',cert,'-days',days,'-extfile',ext,'-extensions','server')
        class TLSHandler(Handler):
            def do_GET(self):
                if self.path == '/__sni':
                    self.send(200, getattr(self.connection, '_bps_sni', '').encode()); return
                if self.path == '/__redirect':
                    self.send(302, headers={'Location':'http://127.0.0.1:9/'}); return
                super().do_GET()
        server=http.server.HTTPServer(('127.0.0.1',0),TLSHandler)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key)
        context.set_servername_callback(lambda sock, name, _: setattr(sock, '_bps_sni', name or ''))
        server.socket=context.wrap_socket(server.socket,server_side=True)
        servers.append(server)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        endpoints[name]=server.server_port
    print(json.dumps(endpoints),flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        for server in servers: server.shutdown();server.server_close()
