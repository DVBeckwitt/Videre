import http from 'node:http';
import { readFileSync } from 'node:fs';
import { isIP } from 'node:net';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { FeedbackStore, StoreError } from './store.mjs';
import { GithubIssueClient, GithubError } from './github.mjs';
import { InputError, MAX_BODY_BYTES, UUID, receiptIsValid, validateReport } from './validation.mjs';

function json(response, status, value, retryAfter) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
    ...(retryAfter ? { 'Retry-After': String(retryAfter) } : {}),
  });
  response.end(body);
}
function publicOrigin(value, allowInsecureLoopback) {
  const url = new URL(value);
  const loopback = ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(allowInsecureLoopback && loopback && url.protocol === 'http:')) || url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('Invalid feedback public origin');
  return url.origin;
}
async function readReport(request) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers['content-type'] ?? '') || request.headers['content-encoding']) throw new InputError('invalid_content_type', 415);
  const declared = Number(request.headers['content-length']);
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) throw new InputError('too_large', 413);
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > MAX_BODY_BYTES) throw new InputError('too_large', 413);
    chunks.push(chunk);
  }
  let data;
  try { data = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))); }
  catch { throw new InputError('invalid_json'); }
  return validateReport(data);
}

/** Constructs the real HTTP relay. Only test code injects a fake GitHub adapter. */
export function createFeedbackServer({ store, github, publicBaseUrl, owner = 'DVBeckwitt', repo = 'Videre', allowInsecureLoopback = false, trustedProxyAddresses = [], trustedProxyHeader = 'x-real-ip', now = Date.now, retryDelayMs = 30_000, maxConcurrentRequests = 8 }) {
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/.test(owner) || !/^[A-Za-z0-9_.-]{1,100}$/.test(repo)) throw new Error('Invalid feedback repository');
  if (!Number.isInteger(maxConcurrentRequests) || maxConcurrentRequests < 1 || maxConcurrentRequests > 32) throw new Error('Invalid submission concurrency limit');
  store.bindRepository(`${owner.toLowerCase()}/${repo.toLowerCase()}`);
  let activeRequests = 0;
  let activeImages = 0;
  const origin = publicOrigin(publicBaseUrl, allowInsecureLoopback);
  const trusted = new Set(trustedProxyAddresses);
  if ([...trusted].some(address => isIP(address) === 0)) throw new Error('Invalid trusted proxy address');
  if (!['x-real-ip', 'cf-connecting-ip'].includes(trustedProxyHeader)) throw new Error('Invalid trusted proxy header');
  const inFlight = new Set();
  function clientIp(request) {
    const remote = request.socket.remoteAddress ?? 'unknown';
    if (!trusted.has(remote)) return remote;
    let copies = 0;
    for (let i = 0; i < request.rawHeaders.length; i += 2) {
      if (request.rawHeaders[i].toLowerCase() === trustedProxyHeader) copies++;
    }
    const forwarded = request.headers[trustedProxyHeader];
    return copies === 1 && typeof forwarded === 'string' && isIP(forwarded) ? forwarded : remote;
  }
  function pending(response) { json(response, 202, { status: 'pending' }, Math.ceil(retryDelayMs / 1000)); }
  const server = http.createServer(async (request, response) => {
    let admitted = false;
    try {
      if (request.method === 'GET' && request.url === '/health') {
        json(response, github.configured ? 200 : 503, { status: github.configured ? 'ready' : 'unavailable', schemaVersion: 1 });
        return;
      }
      const imageRoute = /^\/images\/([^/?]+)\.png$/.exec(request.url ?? '');
      if (request.method === 'GET' && imageRoute && UUID.test(imageRoute[1])) {
        if (activeImages >= 16) { json(response, 503, { error: 'busy' }, 10); return; }
        activeImages++;
        let released = false;
        const release = () => { if (!released) { released = true; activeImages--; } };
        response.once('finish', release);
        response.once('close', release);
        const image = store.image(imageRoute[1].toLowerCase());
        if (!image) { json(response, 404, { error: 'not_found' }); return; }
        response.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': image.length, 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'none'; sandbox", 'Cache-Control': 'public, max-age=86400', 'Content-Disposition': 'inline; filename="feedback.png"' });
        response.end(image);
        return;
      }
      if (request.method !== 'POST' || request.url !== '/v1/reports') { json(response, 404, { error: 'not_found' }); return; }
      // Native clients need no CORS. Do not accept cross-origin browser writes.
      if (request.headers.origin) { json(response, 403, { error: 'origin_not_allowed' }); return; }
      if (!store.allowRequest(clientIp(request), now())) { json(response, 429, { error: 'rate_limited' }, 60); return; }
      if (activeRequests >= maxConcurrentRequests) { json(response, 503, { error: 'busy' }, 10); return; }
      activeRequests++; admitted = true;
      const validated = await readReport(request);
      const { report } = validated;
      const existing = store.get(report.submissionId);
      if (!github.configured && !existing) { json(response, 503, { error: 'unavailable' }); return; }
      const { row, fresh } = store.claim(validated, clientIp(request), now());
      if (row.status === 'created') {
        const savedReceipt = store.receipt(row);
        if (!receiptIsValid(savedReceipt, owner, repo)) { json(response, 503, { error: 'unavailable' }); return; }
        json(response, 200, savedReceipt); return;
      }
      if (!github.configured) { json(response, 503, { error: 'unavailable' }); return; }
      if (inFlight.has(row.id)) { pending(response); return; }
      const marker = `<!-- videre-feedback:${row.id} -->`;
      inFlight.add(row.id);
      try {
        if (row.status === 'pending') {
          if (row.reconciled_at != null && now() - row.reconciled_at < retryDelayMs) { pending(response); return; }
          store.markReconciled(row.id, now());
          try {
            const recovered = await github.findIssue(marker, new Date(row.created_at).toISOString());
            if (receiptIsValid(recovered, owner, repo)) {
              store.markCreated(row.id, recovered);
              json(response, 200, { status: 'created', ...recovered });
              return;
            }
          } catch { /* An uncertain external write remains uncertain. */ }
          pending(response);
          return;
        }
        if (row.status === 'rejected' && now() - row.attempted_at < retryDelayMs) { json(response, 502, { error: 'github_failed' }, Math.ceil(retryDelayMs / 1000)); return; }
        if (!store.markAttempt(row.id, now())) { pending(response); return; }
        try {
          const receipt = await github.createIssue(report, { imageUrl: row.image_id ? `${origin}/images/${row.image_id}.png` : undefined, marker });
          if (!receiptIsValid(receipt, owner, repo)) { pending(response); return; }
          store.markCreated(row.id, receipt);
          json(response, fresh ? 201 : 200, { status: 'created', ...receipt });
        } catch (error) {
          if (error instanceof GithubError && !error.ambiguous) {
            store.markRejected(row.id, now());
            json(response, 502, { error: 'github_failed' }, Math.ceil(retryDelayMs / 1000));
          } else {
            pending(response);
          }
        }
      } finally { inFlight.delete(row.id); }
    } catch (error) {
      if (response.headersSent || response.destroyed) return;
      if (error instanceof InputError || error instanceof StoreError) {
        json(response, error.status, { error: error.code }, error.status === 429 ? 3600 : undefined);
      } else {
        // No request body, address, upstream response or credential is logged.
        json(response, 503, { error: 'unavailable' });
      }
    } finally { if (admitted) activeRequests--; }
  });
  server.requestTimeout = 20_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5000;
  server.maxRequestsPerSocket = 100;
  server.maxConnections = 64;
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });
  return server;
}

export function startFromEnvironment(env = process.env) {
  process.umask(0o077);
  const port = Number(env.PORT ?? 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid feedback port');
  const owner = env.GITHUB_OWNER ?? 'DVBeckwitt';
  const repo = env.GITHUB_REPO ?? 'Videre';
  let key;
  if (env.GITHUB_PRIVATE_KEY_FILE) key = readFileSync(env.GITHUB_PRIVATE_KEY_FILE, 'utf8');
  const github = new GithubIssueClient({ owner, repo, appId: env.GITHUB_APP_ID, installationId: env.GITHUB_INSTALLATION_ID, privateKey: key });
  const store = new FeedbackStore(resolve(env.FEEDBACK_DB ?? './data/feedback.sqlite'));
  let server;
  try {
    server = createFeedbackServer({ store, github, owner, repo, publicBaseUrl: env.PUBLIC_BASE_URL, trustedProxyAddresses: (env.TRUSTED_PROXY_ADDRESSES ?? '').split(',').filter(Boolean), trustedProxyHeader: env.TRUSTED_PROXY_HEADER || 'x-real-ip' });
  } catch (error) { store.close(); throw error; }
  server.listen(port, env.HOST ?? '127.0.0.1', () => process.stdout.write(`Videre feedback service listening; GitHub ${github.configured ? 'configured' : 'unavailable'}.\n`));
  const stop = () => { server.close(() => { store.close(); process.exit(0); }); setTimeout(() => process.exit(1), 10_000).unref(); };
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try { startFromEnvironment(); }
  catch { process.stderr.write('Feedback service configuration is invalid or unavailable.\n'); process.exitCode = 1; }
}
