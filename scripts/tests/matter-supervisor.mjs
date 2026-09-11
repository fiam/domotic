import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, unlink, writeFile } from 'node:fs/promises';
import { createServer, request } from 'node:http';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';
import { supervise } from '../../charts/kube4ha/charts/homeassistant/files/matter/supervisor.mjs';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function call(socket, method, path) {
  return new Promise((resolve, reject) => {
    const req = request({ socketPath: socket, method, path }, response => {
      response.resume();
      response.on('end', () => resolve(response.statusCode));
    });
    req.on('error', reject);
    req.end();
  });
}

async function fixture(t, { ignoreTerm = false, firstStopDelay = 150, stopTimeout = 2000 } = {}) {
  const root = await mkdtemp('/tmp/kube4ha-matter-test-');
  const storage = join(root, 'data');
  const backup = join(root, 'backup');
  const socket = join(root, 'control.sock');
  await mkdir(join(storage, 'server'), { recursive: true });
  await mkdir(backup);
  await writeFile(join(storage, 'server/state'), 'initial');
  const listener = createServer();
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  const code = `
    const http = require('node:http'), fs = require('node:fs');
    const server = http.createServer((req,res) => res.end('{}')).listen(${port}, '127.0.0.1');
    process.on('SIGTERM', () => {
      ${ignoreTerm ? '' : `const state = ${JSON.stringify(join(storage, 'server/state'))}; const delay = fs.readFileSync(state, 'utf8') === 'initial' ? ${firstStopDelay} : 150; setTimeout(() => { fs.writeFileSync(state, 'flushed'); server.close(() => process.exit(0)); }, delay);`}
    });
  `;
  const supervisor = supervise({ command: [process.execPath, '-e', code], storage, backup, socket, image: 'fixture:1.0.0', port, ...(stopTimeout === null ? {} : { stopTimeout }), fatal: () => assert.fail('Unexpected process failure') });
  await supervisor.listen();
  t.after(async () => { await supervisor.close(); await rm(root, { recursive: true, force: true }); });
  async function ready() {
    for (let attempt = 0; attempt < 100; attempt++) {
      if (await call(socket, 'GET', '/health') === 200) return;
      await delay(25);
    }
    assert.fail('Matter process did not restart');
  }
  await ready();
  return { storage, backup, socket, ready };
}

test('snapshot waits for graceful flush, serializes requests, and restarts Matter', async t => {
  const { backup, socket, ready } = await fixture(t);
  const pending = call(socket, 'POST', '/snapshot');
  await delay(40);
  assert.equal(await call(socket, 'GET', '/health'), 200);
  assert.equal(await call(socket, 'POST', '/snapshot'), 409);
  assert.equal(await pending, 200);
  const archive = join(backup, 'latest.tar.gz');
  assert.equal(execFileSync('tar', ['-xOzf', archive, 'server/state'], { encoding: 'utf8' }), 'flushed');
  const metadata = JSON.parse(execFileSync('tar', ['-xOzf', archive, 'metadata.json']));
  assert.equal(metadata.format, 1);
  await ready();
});

test('archive failure preserves the last snapshot and restarts Matter', async t => {
  const { storage, backup, socket, ready } = await fixture(t);
  assert.equal(await call(socket, 'POST', '/snapshot'), 200);
  await ready();
  const before = await readFile(join(backup, 'latest.tar.gz'));
  await symlink('/outside', join(storage, 'server/unsafe'));
  assert.equal(await call(socket, 'POST', '/snapshot'), 500);
  assert.deepEqual(await readFile(join(backup, 'latest.tar.gz')), before);
  await unlink(join(storage, 'server/unsafe'));
  await ready();
});

test('forced termination cannot replace a valid snapshot', async t => {
  const { backup, socket, ready } = await fixture(t, { ignoreTerm: true, stopTimeout: 100 });
  await writeFile(join(backup, 'latest.tar.gz'), 'previous snapshot');
  assert.equal(await call(socket, 'POST', '/snapshot'), 500);
  assert.equal(await readFile(join(backup, 'latest.tar.gz'), 'utf8'), 'previous snapshot');
  await ready();
});

test('default timeout permits a slow WebSocket close before storage flush', async t => {
  const { backup, socket, ready } = await fixture(t, { firstStopDelay: 31000, stopTimeout: null });
  assert.equal(await call(socket, 'POST', '/snapshot'), 200);
  assert.equal(execFileSync('tar', ['-xOzf', join(backup, 'latest.tar.gz'), 'server/state'], { encoding: 'utf8' }), 'flushed');
  await ready();
});
