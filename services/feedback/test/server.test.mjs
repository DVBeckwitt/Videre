import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, generateKeyPairSync } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import http from 'node:http';
import { FeedbackStore } from '../store.mjs';
import { GithubError, GithubIssueClient } from '../github.mjs';
import { createFeedbackServer } from '../server.mjs';
import { validateReport, sanitizePng, MAX_BODY_BYTES } from '../validation.mjs';
import { png } from './png.mjs';

const report = (extra = {}) => ({ schemaVersion: 1, submissionId: randomUUID(), kind: 'bug', title: 'Playback does not resume', description: 'Changed a backend, then pressed Play.', ...extra });
const receipt = (n = 41) => ({ issueNumber: n, issueUrl: `https://github.com/DVBeckwitt/Videre/issues/${n}` });
const fake = (options = {}) => ({ configured: true, createIssue: async () => receipt(), findIssue: async () => null, ...options });
async function harness(t, { github = fake(), file, storeOptions, clock, retryDelayMs = 30_000, trustedProxyAddresses, trustedProxyHeader, maxConcurrentRequests } = {}) {
  const store = new FeedbackStore(file ?? ':memory:', storeOptions);
  const server = createFeedbackServer({ store, github, publicBaseUrl: 'https://feedback.example.test', now: clock, retryDelayMs, trustedProxyAddresses, trustedProxyHeader, maxConcurrentRequests });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); store.close(); });
  const post = async (data, headers = {}) => {
    const response = await fetch(`${url}/v1/reports`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(data) });
    return { response, body: await response.json() };
  };
  return { store, server, url, post };
}

test('plain bug and suggestion create issues with no optional fields', async t => {
  const seen = [];
  const h = await harness(t, { github: fake({ createIssue: async (data, options) => { seen.push({ data, options }); return receipt(seen.length); } }) });
  for (const kind of ['bug', 'suggestion']) {
    const r = report({ kind }); const result = await h.post(r);
    assert.equal(result.response.status, 201);
    assert.equal(result.body.status, 'created');
    assert.deepEqual(seen.at(-1).data, r);
    assert.equal(seen.at(-1).options.imageUrl, undefined);
    assert.equal(seen.at(-1).options.marker, `<!-- videre-feedback:${r.submissionId} -->`);
  }
});

test('optional diagnostics and screenshot preserve image while removing metadata', async t => {
  let options;
  const h = await harness(t, { github: fake({ createIssue: async (_r, o) => { options = o; return receipt(); } }) });
  const r = report({ diagnostics: { proxyEnabled: true, alternativeCount: 2, appVersion: '1.22.30' }, screenshot: { mimeType: 'image/png', base64: png({ metadata: true }).toString('base64') } });
  const result = await h.post(r);
  assert.equal(result.response.status, 201);
  assert.match(options.imageUrl, /^https:\/\/feedback\.example\.test\/images\/[0-9a-f-]+\.png$/);
  const image = await fetch(`${h.url}${new URL(options.imageUrl).pathname}`);
  assert.equal(image.status, 200);
  assert.equal(image.headers.get('content-type'), 'image/png');
  assert.equal(image.headers.get('x-content-type-options'), 'nosniff');
  const bytes = Buffer.from(await image.arrayBuffer());
  assert.ok(bytes.equals(png()));
  assert.equal(bytes.includes(Buffer.from('private metadata')), false);
});

test('same ID and payload returns durable receipt without creating twice', async t => {
  let creates = 0;
  const h = await harness(t, { github: fake({ createIssue: async () => { creates++; return receipt(); } }) });
  const r = report();
  assert.equal((await h.post(r)).response.status, 201);
  assert.equal((await h.post(r)).response.status, 200);
  assert.equal(creates, 1);
  assert.equal((await h.post({ ...r, description: 'Different' })).response.status, 409);
  assert.equal(creates, 1);
});

test('concurrent duplicate returns pending then one receipt', async t => {
  let release; let creates = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const h = await harness(t, { github: fake({ createIssue: async () => { creates++; await gate; return receipt(); } }) });
  const r = report(); const first = h.post(r);
  while (creates === 0) await new Promise(resolve => setTimeout(resolve, 5));
  const second = await h.post(r);
  assert.equal(second.response.status, 202);
  assert.deepEqual(second.body, { status: 'pending' });
  release(); assert.equal((await first).response.status, 201);
  assert.equal((await h.post(r)).response.status, 200);
  assert.equal(creates, 1);
});

test('uncertain create is reconciled without another external write', async t => {
  let creates = 0; let lookups = 0;
  const h = await harness(t, { github: fake({ createIssue: async () => { creates++; throw new GithubError('timeout', { ambiguous: true }); }, findIssue: async () => { lookups++; return receipt(); } }) });
  const r = report();
  assert.equal((await h.post(r)).response.status, 202);
  const recovered = await h.post(r);
  assert.equal(recovered.response.status, 200);
  assert.equal(recovered.body.issueNumber, 41);
  assert.equal(creates, 1); assert.equal(lookups, 1);
});

test('unknown create outcome and missing reconciliation remain pending', async t => {
  let creates = 0; let lookups = 0;
  const h = await harness(t, { github: fake({ createIssue: async () => { creates++; throw new Error('possibly posted, never log me'); }, findIssue: async () => { lookups++; return null; } }) });
  const r = report();
  for (let n = 0; n < 4; n++) assert.equal((await h.post(r)).response.status, 202);
  assert.equal(creates, 1); assert.equal(lookups, 1);
});

test('invalid upstream receipt is never reported as created', async t => {
  let creates = 0;
  const h = await harness(t, { github: fake({ createIssue: async () => { creates++; return { issueNumber: 4, issueUrl: 'https://evil.example/issues/4' }; } }) });
  const r = report();
  assert.equal((await h.post(r)).response.status, 202);
  assert.equal((await h.post(r)).response.status, 202);
  assert.equal(creates, 1);
});

test('definitive GitHub rejection allows a later explicit retry only', async t => {
  let creates = 0; let time = 1_000_000;
  const h = await harness(t, { clock: () => time, github: fake({ createIssue: async () => { creates++; if (creates === 1) throw new GithubError('permission', { status: 403 }); return receipt(); } }) });
  const r = report();
  const rejected = await h.post(r);
  assert.equal(rejected.response.status, 502);
  assert.deepEqual(rejected.body, { error: 'github_failed' });
  assert.equal((await h.post(r)).response.status, 502); assert.equal(creates, 1);
  time += 31_000;
  assert.equal((await h.post(r)).response.status, 200); assert.equal(creates, 2);
});

test('SQLite restart preserves confirmed receipts and uncertain attempts', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'videre-feedback-'));
  const path = join(dir, 'feedback.sqlite');
  const first = report(); const pending = report();
  let store = new FeedbackStore(path);
  store.claim(validateReport(first), '127.0.0.1', Date.now()); store.markAttempt(first.submissionId, Date.now()); store.markCreated(first.submissionId, receipt());
  store.claim(validateReport(pending), '127.0.0.1', Date.now()); store.markAttempt(pending.submissionId, Date.now()); store.close();
  store = new FeedbackStore(path);
  assert.equal(store.get(first.submissionId).issue_number, 41);
  assert.equal(store.get(pending.submissionId).status, 'pending');
  store.close();
  let creates = 0;
  const h = await harness(t, { file: path, github: fake({ createIssue: async () => { creates++; return receipt(); }, findIssue: async () => receipt(42) }) });
  assert.equal((await h.post(first)).body.issueNumber, 41);
  assert.equal((await h.post(pending)).body.issueNumber, 42);
  assert.equal(creates, 0);
  t.after(() => rmSync(dir, { recursive: true, force: true }));
});

test('rate limits apply to new reports but not duplicate issue creation', async t => {
  let creates = 0;
  const h = await harness(t, { storeOptions: { perIpHour: 1 }, github: fake({ createIssue: async () => { creates++; return receipt(); } }) });
  const r = report();
  assert.equal((await h.post(r)).response.status, 201);
  assert.equal((await h.post(r)).response.status, 200);
  assert.equal((await h.post(report())).response.status, 429);
  assert.equal(creates, 1);
});

test('spoofed forwarded addresses cannot bypass request limits', async t => {
  const h = await harness(t, { storeOptions: { perIpMinute: 1 } });
  assert.equal((await h.post(report(), { 'X-Real-IP': '1.1.1.1', 'X-Forwarded-For': '1.1.1.1' })).response.status, 201);
  assert.equal((await h.post(report(), { 'X-Real-IP': '8.8.8.8' })).response.status, 429);
});

test('configured exact proxy can provide validated client addresses', async t => {
  const h = await harness(t, { storeOptions: { perIpHour: 1 }, trustedProxyAddresses: ['127.0.0.1'] });
  assert.equal((await h.post(report(), { 'X-Real-IP': '1.1.1.1' })).response.status, 201);
  assert.equal((await h.post(report(), { 'X-Real-IP': '8.8.8.8' })).response.status, 201);
  assert.equal((await h.post(report(), { 'X-Real-IP': '1.1.1.1' })).response.status, 429);
});

test('Cloudflare mode separates validated clients and ignores X-Real-IP', async t => {
  const h = await harness(t, { storeOptions: { perIpHour: 1 }, trustedProxyAddresses: ['127.0.0.1'], trustedProxyHeader: 'cf-connecting-ip' });
  assert.equal((await h.post(report(), { 'CF-Connecting-IP': '1.1.1.1', 'X-Real-IP': '9.9.9.9' })).response.status, 201);
  assert.equal((await h.post(report(), { 'CF-Connecting-IP': '2001:db8::1', 'X-Real-IP': '9.9.9.9' })).response.status, 201);
  assert.equal((await h.post(report(), { 'CF-Connecting-IP': '1.1.1.1', 'X-Real-IP': '8.8.8.8' })).response.status, 429);
  assert.equal((await h.post(report(), { 'X-Real-IP': '1.0.0.1' })).response.status, 201);
  assert.equal((await h.post(report(), { 'X-Real-IP': '8.8.4.4' })).response.status, 429);
});

test('Cloudflare headers cannot bypass default or untrusted-peer limits', async t => {
  for (const config of [{}, { trustedProxyHeader: 'cf-connecting-ip' }, { trustedProxyAddresses: ['127.0.0.2'], trustedProxyHeader: 'cf-connecting-ip' }, { trustedProxyAddresses: ['127.0.0.1'] }]) {
    const h = await harness(t, { ...config, storeOptions: { perIpHour: 1 } });
    assert.equal((await h.post(report(), { 'CF-Connecting-IP': '1.1.1.1' })).response.status, 201);
    assert.equal((await h.post(report(), { 'CF-Connecting-IP': '8.8.8.8' })).response.status, 429);
  }
});

test('malformed, comma-separated and duplicate proxy headers fall back to the peer', async t => {
  for (const trustedProxyHeader of ['x-real-ip', 'cf-connecting-ip']) {
    const h = await harness(t, { storeOptions: { perIpHour: 1 }, trustedProxyAddresses: ['127.0.0.1'], trustedProxyHeader });
    assert.equal((await h.post(report(), { [trustedProxyHeader]: 'not-an-address' })).response.status, 201);
    for (const value of ['', 'unknown', '1.1.1.1, 8.8.8.8', '127.0.0.1:1234']) {
      assert.equal((await h.post(report(), { [trustedProxyHeader]: value })).response.status, 429);
    }
    const duplicateStatus = await new Promise((resolve, reject) => {
      const body = JSON.stringify(report());
      const request = http.request(`${h.url}/v1/reports`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), [trustedProxyHeader]: ['1.1.1.1', '1.1.1.1'] } }, response => {
        response.resume();
        response.once('end', () => resolve(response.statusCode));
        response.once('error', reject);
      });
      request.once('error', reject);
      request.setTimeout(3000, () => request.destroy(new Error('Local test timed out')));
      request.end(body);
    });
    assert.equal(duplicateStatus, 429);
    assert.equal((await h.post(report(), { [trustedProxyHeader]: '1.1.1.1' })).response.status, 201);
  }
});

test('proxy header configuration is restricted to the supported single-address headers', () => {
  const store = new FeedbackStore(':memory:');
  try {
    for (const trustedProxyHeader of ['x-forwarded-for', 'forwarded', '', 'host', 'CF-Connecting-IP']) {
      assert.throws(() => createFeedbackServer({ store, github: fake(), publicBaseUrl: 'https://feedback.example.test', trustedProxyHeader }), /Invalid trusted proxy header/);
    }
  } finally { store.close(); }
});

test('capacity is bounded and reports cannot override destination or attach credentials', async t => {
  const h = await harness(t, { storeOptions: { maxReports: 1 } });
  for (const extra of [{ repo: 'evil' }, { token: 'secret' }, { diagnostics: { cookies: 'SID=secret' } }, { diagnostics: { proxyEnabled: 'false' } }, { diagnostics: { alternativeCount: 3 } }]) assert.equal((await h.post(report(extra))).response.status, 400);
  assert.equal((await h.post(report())).response.status, 201);
  assert.equal((await h.post(report())).response.status, 503);
});

test('unconfigured service reports unavailable, never simulated success', async t => {
  const h = await harness(t, { github: fake({ configured: false }) });
  const health = await fetch(`${h.url}/health`);
  assert.equal(health.status, 503);
  assert.deepEqual(await health.json(), { status: 'unavailable', schemaVersion: 1 });
  assert.equal((await h.post(report())).response.status, 503);
  assert.equal(h.store.db.prepare('SELECT COUNT(*) AS count FROM reports').get().count, 0);
});

test('wrong methods/origins/types and oversized requests are rejected', async t => {
  const h = await harness(t);
  assert.equal((await fetch(`${h.url}/v1/reports`)).status, 404);
  assert.equal((await h.post(report(), { Origin: 'https://evil.test' })).response.status, 403);
  assert.equal((await h.post(report(), { 'Content-Type': 'text/plain' })).response.status, 415);
  assert.equal((await fetch(`${h.url}/v1/reports`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: 'x'.repeat(MAX_BODY_BYTES + 1) })).status, 413);
});

test('screenshot validation rejects URL/SVG/base64 corruption/oversized dimensions', () => {
  for (const screenshot of [{ url: 'https://evil.test/image.png' }, { mimeType: 'image/svg+xml', base64: 'PHN2Zz4=' }, { mimeType: 'image/png', base64: 'invalid!' }, { mimeType: 'image/png', base64: png({ width: 9000 }).toString('base64') }]) assert.throws(() => sanitizePng(screenshot));
  const corrupt = png(); corrupt[40] ^= 1;
  assert.throws(() => sanitizePng({ mimeType: 'image/png', base64: corrupt.toString('base64') }));
  assert.throws(() => sanitizePng({ mimeType: 'image/png', base64: Buffer.concat([png(), Buffer.from('<script>')]).toString('base64') }));
});

test('plaintext public origins and arbitrary test endpoints are rejected', () => {
  const store = new FeedbackStore(':memory:');
  try {
    for (const publicBaseUrl of ['http://feedback.test', 'https://u:p@feedback.test', 'https://feedback.test/path', 'https://feedback.test/?token=secret']) assert.throws(() => createFeedbackServer({ store, github: fake(), publicBaseUrl }));
    assert.throws(() => createFeedbackServer({ store, github: fake(), publicBaseUrl: 'http://192.168.1.2', allowInsecureLoopback: true }));
    const local = createFeedbackServer({ store, github: fake(), publicBaseUrl: 'http://127.0.0.1:18767', allowInsecureLoopback: true });
    local.close();
  } finally { store.close(); }
});

test('concurrent incomplete uploads are capped before buffering another report', async t => {
  const h = await harness(t, { maxConcurrentRequests: 1 });
  const slow = http.request(`${h.url}/v1/reports`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': 1000 } });
  slow.on('error', () => {});
  slow.write('{');
  await new Promise(resolve => setTimeout(resolve, 25));
  const refused = await h.post(report());
  assert.equal(refused.response.status, 503);
  assert.deepEqual(refused.body, { error: 'busy' });
  slow.destroy();
  await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal((await h.post(report())).response.status, 201);
});

test('attempt ownership is atomic across shared SQLite connections', () => {
  const dir = mkdtempSync(join(tmpdir(), 'videre-feedback-cas-'));
  const path = join(dir, 'shared.sqlite');
  const a = new FeedbackStore(path); const b = new FeedbackStore(path);
  try {
    const r = report();
    a.claim(validateReport(r), '127.0.0.1', Date.now());
    assert.equal(a.markAttempt(r.submissionId, Date.now()), true);
    assert.equal(b.markAttempt(r.submissionId, Date.now()), false);
    assert.equal(b.get(r.submissionId).status, 'pending');
  } finally { a.close(); b.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('database repository binding prevents reusing receipts for another project', () => {
  const store = new FeedbackStore(':memory:');
  try {
    store.bindRepository('dvbeckwitt/videre');
    assert.throws(() => store.bindRepository('another/project'));
  } finally { store.close(); }
});
test('image response slots remain held until response completion', async t => {
  const h = await harness(t);
  const r = report({ screenshot: { mimeType: 'image/png', base64: png().toString('base64') } });
  await h.post(r);
  const imageId = h.store.get(r.submissionId).image_id;
  const held = [];
  h.server.prependListener('request', (request, response) => {
    if (request.url === `/images/${imageId}.png` && held.length < 16) {
      const end = response.end.bind(response);
      response.end = (...args) => { held.push(() => end(...args)); return response; };
    }
  });
  const requests = Array.from({ length: 16 }, () => fetch(`${h.url}/images/${imageId}.png`));
  while (held.length < 16) await new Promise(resolve => setTimeout(resolve, 5));
  const busy = await fetch(`${h.url}/images/${imageId}.png`);
  assert.equal(busy.status, 503);
  held.forEach(release => release());
  for (const pending of requests) assert.equal((await pending).status, 200);
  assert.equal((await fetch(`${h.url}/images/${imageId}.png`)).status, 200);
});

test('HTTP submission integrates the real GitHub adapter with a fake remote transport', async t => {
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const requests = [];
  const github = new GithubIssueClient({ owner: 'DVBeckwitt', repo: 'Videre', appId: 'Iv1_test', installationId: '7', privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }), fetchImpl: async (url, options) => {
    requests.push({ url, options });
    if (url === 'https://api.github.com/app/installations/7/access_tokens') return Response.json({ token: 'test-only-token', expires_at: new Date(Date.now() + 3600000).toISOString() }, { status: 201 });
    assert.equal(url, 'https://api.github.com/repos/DVBeckwitt/Videre/issues');
    return Response.json({ number: 99, html_url: 'https://github.com/DVBeckwitt/Videre/issues/99' }, { status: 201 });
  } });
  const h = await harness(t, { github });
  const r = report({ kind: 'suggestion', diagnostics: { playerType: 'video' } });
  const result = await h.post(r);
  assert.equal(result.response.status, 201);
  assert.deepEqual(result.body, { status: 'created', ...receipt(99) });
  assert.equal(requests.length, 2);
  const sent = JSON.parse(requests[1].options.body);
  assert.match(sent.title, /^\[Suggestion\]/);
  assert.ok(sent.body.endsWith(`<!-- videre-feedback:${r.submissionId} -->`));
  assert.equal((await h.post(r)).response.status, 200);
  assert.equal(requests.length, 2);
});
