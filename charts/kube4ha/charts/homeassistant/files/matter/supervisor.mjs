// Own the Matter process so a native HA backup can take a cold, atomic snapshot.
// The control socket is shared only with the HA container; no network API is added.
import { spawn, execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { chmod, mkdtemp, open, readdir, lstat, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';

const run = promisify(execFile);

async function checkTree(path) {
  for (const name of await readdir(path)) {
    const child = join(path, name);
    const stat = await lstat(child);
    if (stat.isDirectory()) await checkTree(child);
    else if (!stat.isFile()) throw new Error('Matter data contains a non-regular file');
  }
}

export async function archiveState({ storage, backup, image }) {
  await checkTree(join(storage, 'server'));
  if (!(await readdir(join(storage, 'server'))).length) throw new Error('Matter data is empty');
  const work = await mkdtemp(join(backup, '.snapshot-'));
  try {
    await writeFile(join(work, 'metadata.json'), JSON.stringify({
      format: 1, server_image: image, created_at: new Date().toISOString(),
    }), { mode: 0o600 });
    const archive = join(work, 'latest.tar.gz');
    await run('tar', ['-czf', archive, '-C', storage, 'server', '-C', work, 'metadata.json'], { timeout: 30000 });
    await run('tar', ['-tzf', archive], { timeout: 30000 });
    await chmod(archive, 0o600);
    const file = await open(archive, 'r');
    try { await file.sync(); } finally { await file.close(); }
    await rename(archive, join(backup, 'latest.tar.gz'));
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}

export function supervise({ command, storage, backup, socket, image, port, stopTimeout = 20000, fatal = () => process.exit(1) }) {
  let child;
  let snapshot;
  let closing = false;
  const expectedExits = new WeakSet();

  function start() {
    if (closing) return;
    child = spawn(command[0], command.slice(1), { stdio: 'inherit' });
    const started = child;
    started.on('error', () => { console.error('Matter process failed to start'); fatal(); });
    started.on('exit', () => {
      if (!expectedExits.has(started) && !closing) {
        console.error('Matter process exited unexpectedly');
        fatal();
      }
    });
  }

  async function stop() {
    const stopped = child;
    if (!stopped || stopped.exitCode !== null || stopped.signalCode !== null) {
      throw new Error('Matter process is not running');
    }
    expectedExits.add(stopped);
    const result = new Promise(resolve => stopped.once('close', (code, signal) => resolve({ code, signal })));
    let forced = false;
    const timer = setTimeout(() => { forced = true; stopped.kill('SIGKILL'); }, stopTimeout);
    stopped.kill('SIGTERM');
    let exit;
    try { exit = await result; } finally { clearTimeout(timer); child = undefined; }
    if (forced || exit.code !== 0 || exit.signal) throw new Error('Matter did not stop cleanly');
  }

  async function healthy() {
    if (!child || child.exitCode !== null || child.signalCode !== null) return false;
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(1500) });
      await response.arrayBuffer();
      return response.ok;
    } catch { return false; }
  }

  const server = createServer(async (request, response) => {
    const reply = (status, body) => {
      response.writeHead(status, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(body));
    };
    if (request.method === 'GET' && request.url === '/health') {
      // An intentional stop for backup must not remove HA from its Service.
      reply(!closing && (snapshot || await healthy()) ? 200 : 503, {});
      return;
    }
    if (request.method !== 'POST' || request.url !== '/snapshot') { reply(404, {}); return; }
    if (closing || snapshot) { reply(409, { error: 'Matter snapshot already in progress' }); return; }
    // Claim the operation before any await so concurrent requests cannot stop
    // the same process twice. Continue even if the HTTP client disconnects.
    snapshot = (async () => {
      if (!await healthy()) throw new Error('Matter is not ready');
      try {
        await stop();
        if (closing) throw new Error('Matter is shutting down');
        await archiveState({ storage, backup, image });
      } finally {
        if (!child) start();
      }
    })();
    try {
      await snapshot;
      console.log('Staged Matter state for the native Home Assistant backup');
      reply(200, { format: 1 });
    } catch {
      console.error('Matter snapshot failed; preserving the previous archive');
      reply(500, { error: 'Matter snapshot failed' });
    } finally { snapshot = undefined; }
  });

  async function listen() {
    await rm(socket, { force: true });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
    await chmod(socket, 0o600);
    start();
  }

  async function close() {
    closing = true;
    server.close();
    if (snapshot) await snapshot.catch(() => {});
    if (child) await stop().catch(() => {});
    await rm(socket, { force: true });
  }
  return { listen, close };
}

// Kubernetes ConfigMap files are symlinks. Compare their resolved paths so
// invoking the mounted script actually starts the supervisor.
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  process.umask(0o077);
  const controller = supervise({
    command: ['node', '--enable-source-maps', '/app/node_modules/matter-server/dist/esm/MatterServer.js'],
    storage: '/data', backup: '/backup', socket: '/run/kube4ha-matter/control.sock',
    image: process.env.MATTER_SERVER_IMAGE, port: process.env.PORT || '5580',
  });
  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.once(signal, async () => { await controller.close(); process.exit(0); });
  }
  await controller.listen();
}
