import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createReadStream, createWriteStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import { createHash, timingSafeEqual } from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const internalPrefix = '.bps-serve-tmp-';
const methods = 'OPTIONS, HEAD, GET, PROPFIND, MKCOL, PUT, DELETE';
const xml = value => String(value).replace(/[<>&"']/g, c => ({
  '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;',
})[c]);
const failure = status => Object.assign(new Error(`HTTP ${status}`), { status });

export async function loadConfig(filename) {
  const absolute = path.resolve(filename);
  const config = JSON.parse(await fs.readFile(absolute, 'utf8'));
  return { ...config, configDirectory: path.dirname(absolute) };
}

// Serial requests keep condition checks + atomic replacement indivisible for
// this single test-server process. Do not run multiple writers on its directory.
export async function createTestServer(config) {
  const { host = '127.0.0.1', port = 8080, rootPath = '/sync/',
    username, password, maxUploadBytes = 512 * 1024 * 1024,
    configDirectory = process.cwd(), tls = null } = config;
  if (typeof host !== 'string' || !Number.isInteger(port) || port < 0 || port > 65535
    || typeof config.directory !== 'string' || !config.directory
    || !/^\/(?:[a-zA-Z0-9._-]+\/)*$/.test(rootPath)
    || rootPath.split('/').some(p => p === '.' || p === '..')
    || typeof username !== 'string' || !username || /[:\r\n]/.test(username)
    || typeof password !== 'string' || !password || /[\r\n]/.test(password)
    || !Number.isSafeInteger(maxUploadBytes) || maxUploadBytes <= 0) {
    throw new Error('配置无效：请检查 host、port、directory、rootPath、账户和上传上限');
  }
  await fs.mkdir(path.resolve(configDirectory, config.directory), { recursive: true });
  const directory = await fs.realpath(path.resolve(configDirectory, config.directory));
  const authDigest = createHash('sha256').update(`Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`).digest();

  async function resolveResource(rawUrl) {
    if (typeof rawUrl !== 'string' || rawUrl.includes('?') || rawUrl.includes('#')) throw failure(400);
    if (rawUrl !== rootPath.slice(0, -1) && !rawUrl.startsWith(rootPath)) throw failure(404);
    const tail = rawUrl === rootPath.slice(0, -1) ? '' : rawUrl.slice(rootPath.length);
    let parts;
    try { parts = tail.split('/').map(decodeURIComponent); } catch { throw failure(400); }
    if (parts.some(p => p === '.' || p === '..' || /[/\\\x00-\x1f\x7f]/.test(p)
      || p.startsWith(internalPrefix))) throw failure(403);
    // Reject repeated separators, allowing only the final collection slash.
    if (parts.slice(0, -1).some(p => p === '')) throw failure(400);
    parts = parts.filter(Boolean);
    let localPath = directory;
    for (let i = 0; i < parts.length; i++) {
      localPath = path.join(localPath, parts[i]);
      const st = await stat(localPath);
      if (st?.isSymbolicLink()) throw failure(403);
      if (i < parts.length - 1 && !st?.isDirectory()) throw failure(409);
    }
    return { localPath, parts };
  }
  async function stat(filename) {
    try { return await fs.lstat(filename); } catch (e) {
      if (e.code === 'ENOENT') return null;
      throw e;
    }
  }
  async function etag(filename, st) {
    if (!st || !st.isFile()) return null;
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(filename)) hash.update(chunk);
    return `"${hash.digest('hex')}"`;
  }
  function checkConditions(req, exists, tag) {
    const match = req.headers['if-match'];
    if (match && (match === '*' ? !exists : !tag || !match.split(/,\s*/).includes(tag))) throw failure(412);
    const none = req.headers['if-none-match'];
    if (none && exists && (none === '*' || (tag && none.split(/,\s*/).some(v => v.replace(/^W\//, '') === tag)))) throw failure(412);
  }
  function send(req, res, status, body = '', headers = {}) {
    if (res.destroyed) return;
    if (!req.readableEnded) req.resume();
    res.writeHead(status, { 'Content-Length': Buffer.byteLength(body), ...headers });
    res.end(req.method === 'HEAD' ? undefined : body);
  }
  async function propertyResponse(localPath, parts) {
    const st = await stat(localPath);
    if (!st || st.isSymbolicLink() || (!st.isFile() && !st.isDirectory())) throw failure(403);
    const tag = await etag(localPath, st);
    const href = rootPath + parts.map(encodeURIComponent).join('/') + (st.isDirectory() && parts.length ? '/' : '');
    return `<d:response><d:href>${xml(href)}</d:href><d:propstat><d:prop>`
      + `<d:resourcetype>${st.isDirectory() ? '<d:collection/>' : ''}</d:resourcetype>`
      + `<d:getcontentlength>${st.isFile() ? st.size : 0}</d:getcontentlength>`
      + `<d:getlastmodified>${xml(st.mtime.toUTCString())}</d:getlastmodified>`
      + (tag ? `<d:getetag>${xml(tag)}</d:getetag>` : '')
      + '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  }
  async function handle(req, res) {
    const provided = createHash('sha256').update(req.headers.authorization || '').digest();
    if (!timingSafeEqual(provided, authDigest)) {
      return send(req, res, 401, 'Authentication required', { 'WWW-Authenticate': 'Basic realm="BaiduPanSync test"' });
    }
    const { localPath, parts } = await resolveResource(req.url);
    const st = await stat(localPath);
    if (st && !st.isFile() && !st.isDirectory()) throw failure(403);
    const tag = await etag(localPath, st);
    if (req.method === 'OPTIONS') return send(req, res, 200, '', { DAV: '1', Allow: methods });
    if (req.method === 'GET' || req.method === 'HEAD') {
      if (!st) throw failure(404);
      if (!st.isFile()) throw failure(405);
      // Download requests use stable, complete files, not upload temporary data.
      checkConditions(req, true, tag);
      const type = localPath.endsWith('.json') ? 'application/json' : localPath.endsWith('.epub') ? 'application/epub+zip' : 'application/octet-stream';
      res.writeHead(200, { 'Content-Length': st.size, 'Content-Type': type, ETag: tag });
      if (req.method === 'HEAD') return res.end();
      return pipeline(createReadStream(localPath), res);
    }
    if (req.method === 'PROPFIND') {
      if (!st) throw failure(404);
      const depth = req.headers.depth ?? '0';
      if (depth !== '0' && depth !== '1') throw failure(403);
      const rows = [await propertyResponse(localPath, parts)];
      if (depth === '1' && st.isDirectory()) {
        const children = await fs.readdir(localPath, { withFileTypes: true });
        for (const child of children.sort((a, b) => a.name.localeCompare(b.name))) {
          if (child.name.startsWith(internalPrefix) || child.isSymbolicLink()) continue;
          if (child.isFile() || child.isDirectory()) rows.push(await propertyResponse(path.join(localPath, child.name), [...parts, child.name]));
        }
      }
      return send(req, res, 207, '<?xml version="1.0" encoding="UTF-8"?><d:multistatus xmlns:d="DAV:">'
        + rows.join('') + '</d:multistatus>', { 'Content-Type': 'application/xml; charset=utf-8', DAV: '1' });
    }
    if (!parts.length) throw failure(403); // never delete/replace the storage root
    if (req.method === 'MKCOL') {
      checkConditions(req, Boolean(st), tag);
      if (st) throw failure(405);
      if (Number(req.headers['content-length'] || 0) || req.headers['transfer-encoding']) throw failure(415);
      await fs.mkdir(localPath);
      return send(req, res, 201);
    }
    if (req.method === 'PUT') {
      if (st?.isDirectory()) throw failure(405);
      checkConditions(req, Boolean(st), tag);
      if (Number(req.headers['content-length']) > maxUploadBytes) throw failure(413);
      const temporary = await fs.mkdtemp(path.join(directory, internalPrefix));
      const upload = path.join(temporary, 'upload');
      let bytes = 0;
      try {
        await pipeline(req, new Transform({ transform(chunk, encoding, callback) {
          bytes += chunk.length;
          callback(bytes > maxUploadBytes ? failure(413) : null, chunk);
        } }), createWriteStream(upload, { flags: 'wx', mode: 0o600 }));
        await fs.rename(upload, localPath);
      } finally { await fs.rm(temporary, { recursive: true, force: true }); }
      return send(req, res, st ? 204 : 201);
    }
    if (req.method === 'DELETE') {
      if (!st) throw failure(404);
      checkConditions(req, true, tag);
      if (st.isDirectory()) await fs.rmdir(localPath); // only empty directories
      else await fs.unlink(localPath);
      return send(req, res, 204);
    }
    return send(req, res, 405, '', { Allow: methods });
  }
  let queued = Promise.resolve();
  const listener = (req, res) => {
    queued = queued.then(async () => {
      try { await handle(req, res); } catch (e) {
        const status = e.status || ({ ENOENT: 409, ENOTDIR: 409, EEXIST: 405, ENOTEMPTY: 409,
          EACCES: 403, EPERM: 403, ENOSPC: 507 })[e.code] || 500;
        if (!res.headersSent) send(req, res, status, `HTTP ${status}`);
        else res.destroy();
      }
    });
  };
  let server;
  if (tls) {
    if (typeof tls.cert !== 'string' || typeof tls.key !== 'string') throw new Error('tls 需要 cert 和 key 文件路径');
    server = https.createServer({ cert: await fs.readFile(path.resolve(configDirectory, tls.cert)),
      key: await fs.readFile(path.resolve(configDirectory, tls.key)), minVersion: 'TLSv1.2' }, listener);
  } else server = http.createServer(listener);
  server.requestTimeout = 120_000;
  server.headersTimeout = 15_000;
  return { server, host, port, rootPath, directory, protocol: tls ? 'https' : 'http' };
}

async function main() {
  const filename = process.argv[2] || fileURLToPath(new URL('./config.json', import.meta.url));
  const service = await createTestServer(await loadConfig(filename));
  service.server.on('error', e => { console.error(`服务启动失败：${e.code || e.message}`); process.exitCode = 1; });
  service.server.listen(service.port, service.host, () => {
    console.log(`WebDAV: ${service.protocol}://${service.host}:${service.server.address().port}${service.rootPath}`);
    console.log(`存储目录: ${service.directory}`);
    if (service.protocol === 'http') console.log('HTTP 为明文传输，仅用于可信局域网测试。');
  });
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
    service.server.close();
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(e => { console.error(`服务启动失败：${e.message}`); process.exitCode = 1; });
}
