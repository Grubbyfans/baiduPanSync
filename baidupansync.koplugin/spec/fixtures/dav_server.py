"""Isolated in-memory DAV fixture. Never reads/writes the real library."""
import hashlib
import http.server
import sys
from xml.sax.saxutils import escape
files = {}
dirs = {'/sync/'}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, code, body=b'', headers=None):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        for k,v in (headers or {}).items(): self.send_header(k,v)
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)
    def auth(self):
        if self.headers.get('Authorization') != 'Basic dTpw': self.send(401); return False
        return True
    def do_MKCOL(self):
        if not self.auth(): return
        p=self.path.rstrip('/')+'/'
        if p in dirs: self.send(405); return
        dirs.add(p); self.send(201)
    def do_PUT(self):
        if not self.auth(): return
        data=self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.headers.get('If-None-Match') == '*' and self.path in files: self.send(412); return
        current=files.get(self.path)
        if self.headers.get('If-Match') and (current is None or self.headers['If-Match']!=self.etag(current)):
            self.send(412); return
        files[self.path]=data; self.send(201)
    def etag(self, b): return '"'+hashlib.sha256(b).hexdigest()+'"'
    def do_GET(self):
        if not self.auth(): return
        if self.path not in files: self.send(404); return
        b=files[self.path]; self.send(200,b,{'ETag':self.etag(b)})
    do_HEAD=do_GET
    def do_DELETE(self):
        if not self.auth(): return
        if self.path not in files: self.send(404); return
        if self.headers.get('If-Match') and self.headers['If-Match'] != self.etag(files[self.path]): self.send(412); return
        del files[self.path]; self.send(204)
    def do_PROPFIND(self):
        if not self.auth(): return
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        prefix=self.path.rstrip('/')+'/'
        rows=[]
        candidates = files.items()
        if self.headers.get('Depth') == '0':
            directory = self.path.rstrip('/')+'/'
            if directory in dirs:
                self.send(207, ('<d:multistatus xmlns:d="DAV:"><d:response><d:href>'+escape(directory)+
                    '</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>'
                    '<d:getcontentlength>0</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
                    '</d:propstat></d:response></d:multistatus>').encode()); return
            if self.path not in files: self.send(404); return
            candidates = [(self.path, files[self.path])]
        for p,b in candidates:
            if self.headers.get('Depth') == '0' or (p.startswith(prefix) and '/' not in p[len(prefix):]):
                rows.append('<d:response><d:href>'+escape(p)+'</d:href><d:propstat><d:prop><d:resourcetype/>'
                    '<d:getcontentlength>'+str(len(b))+'</d:getcontentlength><d:getetag>'+escape(self.etag(b))+
                    '</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        self.send(207, ('<d:multistatus xmlns:d="DAV:">'+''.join(rows)+'</d:multistatus>').encode())
if __name__ == '__main__':
    server=http.server.HTTPServer(('127.0.0.1',0),Handler)
    print(server.server_port,flush=True)
    server.serve_forever()
