// Disposable filesystem-backed Node server + the complete KOReader spec suite.
import { createTestServer } from './server.js';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'bps-node-plugin-'));
let service;
try {
  service = await createTestServer({ host: '127.0.0.1', port: 0, directory: 'data',
    configDirectory: temporary, username: 'u', password: 'p' });
  await new Promise((resolve, reject) => {
    service.server.once('error', reject);
    service.server.listen(0, '127.0.0.1', resolve);
  });
  const root = fileURLToPath(new URL('../', import.meta.url));
  process.exitCode = await new Promise(resolve => {
    const child = spawn('python3', ['baidupansync.koplugin/spec/run_network.py'], {
      cwd: root, stdio: 'inherit', env: { ...process.env,
        BPS_DAV_TEST_URL: `http://127.0.0.1:${service.server.address().port}/sync/` },
    });
    child.on('error', () => resolve(1));
    child.on('exit', code => resolve(code ?? 1));
  });
} finally {
  if (service) await new Promise(resolve => service.server.close(resolve));
  await fs.rm(temporary, { recursive: true, force: true });
}
