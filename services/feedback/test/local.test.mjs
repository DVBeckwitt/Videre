import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { checkNodeVersion, defaultConfigPath, initializeLocalConfig, readLocalConfiguration } from '../local.mjs';

const localScript = fileURLToPath(new URL('../local.mjs', import.meta.url));
const repository = resolve(dirname(localScript), '../..');
const rsaKey = generateKeyPairSync('rsa', { modulusLength: 2048, privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } }).privateKey;
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'videre-local-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const config = join(dir, 'feedback.env');
  const key = join(dir, 'test-key.pem');
  writeFileSync(key, rsaKey, { mode: 0o600 });
  const values = { PUBLIC_BASE_URL: 'https://feedback.example.test', GITHUB_APP_ID: '12345', GITHUB_INSTALLATION_ID: '67890', GITHUB_PRIVATE_KEY_FILE: key, HOST: '127.0.0.1', PORT: '8787' };
  const write = (extra = {}) => {
    const settings = { ...values, ...extra };
    writeFileSync(config, Object.entries(settings).map(([k, v]) => `${k}='${v}'`).join('\n'), { mode: 0o600 });
    return config;
  };
  return { dir, config, key, write };
}
function rejects(config, code) { assert.throws(() => readLocalConfiguration(config), error => error.message === code); }

test('Node version follows the repository pin and supported major', () => {
  for (const version of ['24.22.1', '24.22.2', '24.23.0']) assert.doesNotThrow(() => checkNodeVersion(version));
  for (const version of ['24.22.0', '24.21.99', '23.99.0', '25.0.0', '24.22.1-extra', 'oops']) assert.throws(() => checkNodeVersion(version), /unsupported_node_version/);
});

test('default configuration location is durable user data, not the cwd', () => {
  assert.equal(defaultConfigPath({ platform: 'win32', localAppData: tmpdir() }), join(tmpdir(), 'VidereFeedback', 'feedback.env'));
  assert.equal(defaultConfigPath({ platform: 'linux', home: tmpdir() }), join(tmpdir(), '.local', 'share', 'videre-feedback', 'feedback.env'));
  assert.throws(() => defaultConfigPath({ platform: 'win32', localAppData: '' }), /local_app_data_unavailable/);
});

test('init creates an unavailable template and never overwrites existing configuration', t => {
  const f = fixture(t);
  initializeLocalConfig(f.config);
  const original = readFileSync(f.config, 'utf8');
  assert.match(original, /^PUBLIC_BASE_URL=$/m);
  assert.match(original, /^GITHUB_PRIVATE_KEY_FILE=$/m);
  assert.throws(() => initializeLocalConfig(f.config), /configuration_already_exists/);
  assert.equal(readFileSync(f.config, 'utf8'), original);
  rejects(f.config, 'https_origin_required');
  assert.equal(existsSync(join(f.dir, 'data')), false);
});

test('configuration errors do not expose credential values', t => {
  const f = fixture(t);
  rejects(f.config, 'configuration_missing');
  f.write({ GITHUB_APP_ID: '' }); rejects(f.config, 'github_ids_required');
  f.write({ GITHUB_PRIVATE_KEY_FILE: '' }); rejects(f.config, 'github_key_required');
  f.write({ GITHUB_PRIVATE_KEY_FILE: join(f.dir, 'missing.pem') }); rejects(f.config, 'github_key_unavailable');
  f.write({ GITHUB_APP_ID: 'a-secret-invalid-@-id' }); rejects(f.config, 'github_configuration_invalid');
  writeFileSync(f.key, 'sensitive-private-key-text');
  f.write(); rejects(f.config, 'github_configuration_invalid');
  const weakKey = generateKeyPairSync('rsa', { modulusLength: 1024, privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } }).privateKey;
  writeFileSync(f.key, weakKey);
  rejects(f.config, 'github_configuration_invalid');
});

test('only full HTTPS origins and loopback binding are accepted', t => {
  const f = fixture(t);
  for (const origin of ['', 'http://localhost:8787', 'https://u:p@example.test', 'https://example.test/reports', 'https://example.test/?token=secret', 'https://example.test/#fragment']) {
    f.write({ PUBLIC_BASE_URL: origin }); rejects(f.config, 'https_origin_required');
  }
  for (const host of ['0.0.0.0', 'localhost', '::', '192.168.1.2']) { f.write({ HOST: host }); rejects(f.config, 'loopback_host_required'); }
  f.write({ TRUSTED_PROXY_ADDRESSES: '127.0.0.1' }); rejects(f.config, 'proxy_trust_managed_by_proxy_mode');
  for (const port of ['0', '65536', '-1', '8787junk']) { f.write({ PORT: port }); rejects(f.config, 'port_invalid'); }
  f.write({ PUBLIC_BASE_URL: 'https://feedback.example.test:8443/' });
  assert.equal(readLocalConfiguration(f.config).PUBLIC_BASE_URL, 'https://feedback.example.test:8443');
});

test('config, private key and database require absolute paths outside the repository', t => {
  const f = fixture(t);
  assert.throws(() => initializeLocalConfig('feedback.env'), /absolute_path_required/);
  assert.throws(() => initializeLocalConfig(join(repository, 'local-private.env')), /path_inside_repository/);
  f.write({ GITHUB_PRIVATE_KEY_FILE: 'relative.pem' }); rejects(f.config, 'absolute_path_required');
  f.write({ GITHUB_PRIVATE_KEY_FILE: join(repository, 'private-key.pem') }); rejects(f.config, 'path_inside_repository');
  f.write({ FEEDBACK_DB: 'data/feedback.sqlite' }); rejects(f.config, 'absolute_path_required');
  f.write({ FEEDBACK_DB: join(repository, 'data', 'feedback.sqlite') }); rejects(f.config, 'path_inside_repository');
  f.write({ FEEDBACK_DB: f.key }); rejects(f.config, 'database_path_conflicts');
  f.write({ FEEDBACK_DB: f.config }); rejects(f.config, 'database_path_conflicts');
  const otherCheckout = join(f.dir, 'other-checkout');
  mkdirSync(join(otherCheckout, '.git'), { recursive: true });
  assert.throws(() => initializeLocalConfig(join(otherCheckout, 'feedback.env')), /path_inside_repository/);
  const link = join(f.dir, 'checkout-link');
  symlinkSync(repository, link, 'junction');
  assert.throws(() => initializeLocalConfig(join(link, 'feedback.env')), /path_inside_repository/);
});

test('effective configuration excludes inherited service settings and defaults DB beside config', t => {
  const f = fixture(t); f.write();
  const inherited = { HOST: '0.0.0.0', FEEDBACK_DB: join(repository, 'should-not-exist.sqlite'), GITHUB_APP_ID: 'unrelated', GITHUB_PRIVATE_KEY_FILE: 'do-not-read', PROXY_MODE: 'cloudflare', TRUSTED_PROXY_ADDRESSES: '127.0.0.1', TRUSTED_PROXY_HEADER: 'cf-connecting-ip' };
  const prior = Object.fromEntries(Object.keys(inherited).map(key => [key, process.env[key]]));
  try {
    Object.assign(process.env, inherited);
    const config = readLocalConfiguration(f.config);
    assert.equal(config.HOST, '127.0.0.1');
    assert.equal(config.FEEDBACK_DB, join(f.dir, 'data', 'feedback.sqlite'));
    assert.equal(config.GITHUB_PRIVATE_KEY_FILE, f.key);
    assert.equal(config.GITHUB_APP_ID, '12345');
    assert.equal(config.TRUSTED_PROXY_ADDRESSES, '');
    assert.equal(config.TRUSTED_PROXY_HEADER, 'x-real-ip');
    assert.equal(existsSync(join(f.dir, 'data')), false);
  } finally {
    for (const [key, value] of Object.entries(prior)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  }
  f.write({ NODE_OPTIONS: '--inspect' }); rejects(f.config, 'unknown_configuration_key');
});

test('local proxy mode derives a narrow Cloudflare trust configuration', t => {
  const f = fixture(t);
  f.write({ PROXY_MODE: 'cloudflare' });
  const cloudflare = readLocalConfiguration(f.config);
  assert.equal(cloudflare.HOST, '127.0.0.1');
  assert.equal(cloudflare.TRUSTED_PROXY_ADDRESSES, '127.0.0.1');
  assert.equal(cloudflare.TRUSTED_PROXY_HEADER, 'cf-connecting-ip');
  f.write({ PROXY_MODE: 'none' });
  assert.equal(readLocalConfiguration(f.config).TRUSTED_PROXY_ADDRESSES, '');
  for (const mode of ['Cloudflare', 'generic', 'true']) { f.write({ PROXY_MODE: mode }); rejects(f.config, 'proxy_mode_invalid'); }
  for (const mode of ['none', 'cloudflare']) {
    f.write({ PROXY_MODE: mode, TRUSTED_PROXY_ADDRESSES: '127.0.0.1' }); rejects(f.config, 'proxy_trust_managed_by_proxy_mode');
    f.write({ PROXY_MODE: mode, TRUSTED_PROXY_HEADER: 'cf-connecting-ip' }); rejects(f.config, 'proxy_trust_managed_by_proxy_mode');
  }
});

test('CLI check works from an independent cwd, starts nothing and logs no secrets', t => {
  const f = fixture(t); f.write();
  const result = spawnSync(process.execPath, [localScript, 'check', f.config], { cwd: tmpdir(), encoding: 'utf8', env: { ...process.env, HOST: '0.0.0.0' } });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /structurally ready/);
  assert.match(result.stdout, /Nothing is running/);
  assert.equal(existsSync(join(f.dir, 'data')), false);
  assert.equal(result.stdout.includes(rsaKey), false);
  f.write({ GITHUB_APP_ID: 'sensitive@invalid' });
  const invalid = spawnSync(process.execPath, [localScript, 'check', f.config], { cwd: tmpdir(), encoding: 'utf8' });
  assert.equal(invalid.status, 1);
  assert.match(invalid.stderr, /github_configuration_invalid/);
  assert.equal(invalid.stderr.includes('sensitive@invalid'), false);
});

test('foreground launcher serves loopback health and Cloudflare rate limits without GitHub writes', async t => {
  const f = fixture(t);
  const reservation = net.createServer();
  reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  f.write({ PORT: String(port), PROXY_MODE: 'cloudflare' });
  const child = spawn(process.execPath, [localScript, 'start', f.config], { cwd: tmpdir(), stdio: ['ignore', 'pipe', 'pipe'] });
  let output = ''; let errors = '';
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { errors += data; });
  try {
    const deadline = Date.now() + 10_000;
    while (!output.includes('service listening') && child.exitCode === null && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
    assert.match(output, /service listening/, errors);
    const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(3000) });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: 'ready', schemaVersion: 1 });
    assert.equal(existsSync(join(f.dir, 'data', 'feedback.sqlite')), true);
    // Invalid bodies are rejected before any GitHub call, but consume the
    // per-address request quota, proving the CLI passed its derived header.
    const invalidPost = async address => {
      const result = await fetch(`http://127.0.0.1:${port}/v1/reports`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': address }, body: '{}', signal: AbortSignal.timeout(3000) });
      await result.arrayBuffer();
      return result.status;
    };
    const untilNextMinute = 60_000 - (Date.now() % 60_000);
    if (untilNextMinute < 2000) await new Promise(resolve => setTimeout(resolve, untilNextMinute + 20));
    for (let n = 0; n < 30; n++) assert.equal(await invalidPost('1.1.1.1'), 400);
    assert.equal(await invalidPost('8.8.8.8'), 400);
    assert.equal(await invalidPost('1.1.1.1'), 429);
  } finally {
    if (child.exitCode === null) { const stopped = once(child, 'exit'); child.kill('SIGTERM'); await stopped; }
  }
});
