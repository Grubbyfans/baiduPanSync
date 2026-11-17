import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createTestServer, loadConfig } from './server.js';

const authorization = `Basic ${Buffer.from('u:p').toString('base64')}`;

test('filesystem WebDAV test server', async t => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'bps-node-test-'));
  const service = await createTestServer({ directory: 'books', configDirectory: temporary,
    host: '127.0.0.1', port: 0, username: 'u', password: 'p', maxUploadBytes: 1024 });
  await new Promise(resolve => service.server.listen(0, '127.0.0.1', resolve));
  const port = service.server.address().port;
  const request = (method, resource, body = '', headers = {}) => new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port, method, path: resource, agent: false,
      headers: { Authorization: authorization, 'Content-Length': Buffer.byteLength(body), ...headers } }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() }));
      res.on('error', reject);
    });
    req.on('error', reject);
    req.end(body);
  });
  try {
    await t.test('reads configuration relative to the config file', async () => {
      await fs.writeFile(path.join(temporary, 'config.json'), JSON.stringify({ directory: './content' }));
      const config = await loadConfig(path.join(temporary, 'config.json'));
      assert.equal(config.configDirectory, temporary);
      assert.equal(service.directory, await fs.realpath(path.join(temporary, 'books')));
    });
    await t.test('requires credentials and confines the URL root', async () => {
      assert.equal((await request('GET', '/sync/', '', { Authorization: 'Basic invalid' })).status, 401);
      assert.equal((await request('PROPFIND', '/elsewhere/')).status, 404);
      assert.equal((await request('OPTIONS', '/sync/')).headers.dav, '1');
    });
    await t.test('creates collections and supports streamed upload/download and HEAD', async () => {
      assert.equal((await request('MKCOL', '/sync/books')).status, 201);
      assert.equal((await request('MKCOL', '/sync/books')).status, 405);
      assert.equal((await request('PUT', '/sync/books/test.epub', 'epub bytes', { 'If-None-Match': '*' })).status, 201);
      const downloaded = await request('GET', '/sync/books/test.epub');
      assert.equal(downloaded.body, 'epub bytes');
      assert.match(downloaded.headers.etag, /^"[a-f0-9]{64}"$/);
      const head = await request('HEAD', '/sync/books/test.epub');
      assert.equal(head.body, '');
      assert.equal(Number(head.headers['content-length']), 10);
      assert.equal(head.headers.etag, downloaded.headers.etag);
      assert.equal(await fs.readFile(path.join(service.directory, 'books/test.epub'), 'utf8'), 'epub bytes');
    });
    await t.test('serializes simultaneous conditional creates without lost data', async () => {
      const results = await Promise.all(['first', 'second'].map(body => request('PUT', '/sync/race.json', body, { 'If-None-Match': '*' })));
      assert.deepEqual(results.map(r => r.status).sort(), [201, 412]);
      const winner = results[0].status === 201 ? 'first' : 'second';
      assert.equal((await request('GET', '/sync/race.json')).body, winner);
    });
    await t.test('enforces strong If-Match on replacements and deletion', async () => {
      const before = await request('GET', '/sync/race.json');
      assert.equal((await request('PUT', '/sync/race.json', 'wrong', { 'If-Match': '"wrong"' })).status, 412);
      assert.equal((await request('PUT', '/sync/race.json', 'weak', { 'If-Match': `W/${before.headers.etag}` })).status, 412);
      assert.equal((await request('GET', '/sync/race.json')).body, before.body);
      assert.equal((await request('PUT', '/sync/race.json', 'updated', { 'If-Match': before.headers.etag })).status, 204);
      assert.equal((await request('DELETE', '/sync/race.json', '', { 'If-Match': before.headers.etag })).status, 412);
      assert.equal((await request('DELETE', '/sync/race.json')).status, 204);
      assert.equal((await request('GET', '/sync/race.json')).status, 404);
    });
    await t.test('returns DAV namespace, escaped names and directory/file properties', async () => {
      assert.equal((await request('PUT', '/sync/books/a%26b.json', '{}')).status, 201);
      const listed = await request('PROPFIND', '/sync/books/', '', { Depth: '1' });
      assert.equal(listed.status, 207);
      assert.match(listed.body, /xmlns:d="DAV:"/);
      assert.match(listed.body, /<d:collection\/>/);
      assert.match(listed.body, /a%26b.json/);
      assert.match(listed.body, /&quot;[a-f0-9]{64}&quot;/);
      const stat = await request('PROPFIND', '/sync/books/test.epub', '', { Depth: '0' });
      assert.equal((stat.body.match(/<d:response>/g) || []).length, 1);
      assert.match(stat.body, /<d:getcontentlength>10<\/d:getcontentlength>/);
      assert.equal((await request('PROPFIND', '/sync/', '', { Depth: 'infinity' })).status, 403);
    });
    await t.test('rejects traversal, symlinks, oversized writes and destructive directory deletion', async () => {
      for (const url of ['/sync/../secret', '/sync/%2e%2e/secret', '/sync/x%2Fy', '/sync/x%5Cy']) {
        assert.equal((await request('PUT', url, 'bad')).status, 403);
      }
      await fs.writeFile(path.join(temporary, 'outside.txt'), 'outside');
      await fs.symlink(path.join(temporary, 'outside.txt'), path.join(service.directory, 'link.txt'));
      assert.equal((await request('GET', '/sync/link.txt')).status, 403);
      assert.equal((await request('PUT', '/sync/books/test.epub', 'x'.repeat(1025))).status, 413);
      assert.equal((await request('GET', '/sync/books/test.epub')).body, 'epub bytes');
      assert.equal((await request('DELETE', '/sync/books/')).status, 409);
      assert.equal((await request('DELETE', '/sync/')).status, 403);
      assert.equal((await request('DELETE', '/sync/books/a%26b.json')).status, 204);
    });
    await t.test('aborted upload preserves the existing file and removes temporary data', async () => {
      const started = new Promise(resolve => service.server.once('request', resolve));
      const interrupted = http.request({ hostname: '127.0.0.1', port, method: 'PUT',
        path: '/sync/books/test.epub', agent: false,
        headers: { Authorization: authorization, 'Content-Length': '1000' } });
      interrupted.on('error', () => {});
      interrupted.write('partial');
      await started;
      interrupted.destroy();
      assert.equal((await request('GET', '/sync/books/test.epub')).body, 'epub bytes');
      assert.equal((await fs.readdir(service.directory)).some(name => name.startsWith('.bps-serve-tmp-')), false);
    });
    await t.test('missing parents do not silently create directories', async () => {
      assert.equal((await request('PUT', '/sync/missing/file.json', '{}')).status, 409);
      assert.equal((await request('MOVE', '/sync/books/test.epub')).status, 405);
    });
  } finally {
    await new Promise(resolve => service.server.close(resolve));
    await fs.rm(temporary, { recursive: true, force: true });
  }
});
