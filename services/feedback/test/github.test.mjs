import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import test from 'node:test';
import { GithubError, GithubIssueClient } from '../github.mjs';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' });
const time = Date.parse('2026-10-30T18:00:00Z');
const marker = '<!-- videre-feedback:98c3fae7-89b6-49c4-afc8-5c20c1674bf9 -->';
const report = { kind: 'bug', title: 'Playback stopped', description: 'After choosing another backend.' };
const issue = { number: 42, html_url: 'https://github.com/DVBeckwitt/Videre/issues/42' };
const response = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
const tokenResponse = () => response({ token: 'test-installation-token', expires_at: new Date(time + 3_600_000).toISOString() }, 201);

function client(fetchImpl, overrides = {}) {
  return new GithubIssueClient({ owner: 'DVBeckwitt', repo: 'Videre', appId: 'Iv1_app', installationId: '12', privateKey: privatePem, now: () => time, fetchImpl, ...overrides });
}

test('uses a valid RS256 JWT and a repository-scoped installation token', async () => {
  const calls = [];
  const github = client(async (url, options) => {
    calls.push({ url, options });
    return calls.length === 1 ? tokenResponse() : response(issue, 201);
  });
  assert.equal(github.configured, true);
  assert.deepEqual(await github.createIssue(report, { marker }), { issueNumber: 42, issueUrl: issue.html_url });
  const auth = calls[0].options.headers.Authorization.slice('Bearer '.length);
  const parts = auth.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(parts[0], 'base64url')), { alg: 'RS256', typ: 'JWT' });
  const claims = JSON.parse(Buffer.from(parts[1], 'base64url'));
  assert.equal(claims.iat, time / 1000 - 60);
  assert.equal(claims.exp, time / 1000 + 540);
  assert.equal(claims.iss, 'Iv1_app');
  assert.equal(verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), publicKey, Buffer.from(parts[2], 'base64url')), true);
  assert.deepEqual(JSON.parse(calls[0].options.body), { repositories: ['Videre'], permissions: { issues: 'write' } });
  assert.equal(calls[1].options.headers.Authorization, 'Bearer test-installation-token');
  assert.equal(calls[1].options.headers['X-GitHub-Api-Version'], '2026-03-10');
  assert.equal(calls[1].options.redirect, 'error');
  assert.equal(calls[1].url, 'https://api.github.com/repos/DVBeckwitt/Videre/issues');
});

test('plain text reports cannot create rendered remote images, mentions, or HTML', async () => {
  let body;
  const github = client(async (url, options) => {
    if (url.endsWith('/access_tokens')) return tokenResponse();
    body = JSON.parse(options.body);
    return response(issue, 201);
  });
  const description = '```\n@maintainer ![tracking](https://untrusted.test/image)\n<script>alert(1)</script>\n````';
  await github.createIssue({ ...report, title: '@maintainer', description }, { marker });
  assert.equal(body.title, '[Bug] @\u200bmaintainer');
  assert.ok(body.body.includes(`\`\`\`\`\`text\n${description}\n\`\`\`\`\``));
  assert.ok(body.body.endsWith(`\n\n${marker}`));
  assert.equal(body.body.includes('## Optional screenshot'), false);
  assert.equal(body.body.includes('## Optional diagnostics'), false);
  assert.equal(body.labels, undefined);
});

test('optional diagnostics and service-hosted screenshot appear only when supplied', async () => {
  let body;
  const github = client(async (url, options) => {
    if (url.endsWith('/access_tokens')) return tokenResponse();
    body = JSON.parse(options.body);
    return response(issue, 201);
  });
  await github.createIssue({ ...report, kind: 'suggestion', diagnostics: { appVersion: '1.2.3', proxyEnabled: true } }, { marker, imageUrl: 'https://feedback.example/images/example.png' });
  assert.equal(body.title, '[Suggestion] Playback stopped');
  assert.ok(body.body.includes('"proxyEnabled": true'));
  assert.ok(body.body.includes('![Screenshot supplied by the reporter](https://feedback.example/images/example.png)'));
});

test('missing or malformed credentials fail before any network operation', async () => {
  for (const overrides of [{ privateKey: undefined }, { owner: '../evil' }, { installationId: '-1' }, { appId: '' }]) {
    const github = client(() => assert.fail('Must not fetch'), overrides);
    assert.equal(github.configured, false);
    await assert.rejects(github.createIssue(report, { marker }), (error) => error instanceof GithubError && error.code === 'github_unconfigured' && !error.ambiguous);
  }
});

test('valid token is reused and refreshed before expiry', async () => {
  let now = time;
  let tokens = 0;
  const github = client(async (url) => {
    if (url.endsWith('/access_tokens')) {
      tokens += 1;
      return response({ token: `token-${tokens}`, expires_at: new Date(now + 120_000).toISOString() }, 201);
    }
    return response(issue, 201);
  }, { now: () => now });
  await github.createIssue(report, { marker });
  await github.createIssue(report, { marker });
  assert.equal(tokens, 1);
  now += 61_000;
  await github.createIssue(report, { marker });
  assert.equal(tokens, 2);
});

test('concurrent callers share installation-token creation', async () => {
  let tokens = 0;
  const github = client(async (url) => {
    if (url.endsWith('/access_tokens')) {
      tokens += 1;
      await new Promise((resolve) => setTimeout(resolve, 5));
      return tokenResponse();
    }
    return response(issue, 201);
  });
  await Promise.all([github.createIssue(report, { marker }), github.createIssue(report, { marker })]);
  assert.equal(tokens, 1);
});

test('an explicit retry after 401 obtains a fresh token without automatic create retry', async () => {
  let tokens = 0;
  let attempts = 0;
  const github = client(async (url) => {
    if (url.endsWith('/access_tokens')) {
      tokens += 1;
      return tokenResponse();
    }
    attempts += 1;
    return attempts === 1 ? response({}, 401) : response(issue, 201);
  });
  await assert.rejects(github.createIssue(report, { marker }), (error) => error.status === 401 && !error.ambiguous);
  assert.equal(attempts, 1);
  await github.createIssue(report, { marker });
  assert.equal(tokens, 2);
  assert.equal(attempts, 2);
});

test('invalid token response is definitive because no issue POST occurred', async () => {
  let calls = 0;
  const github = client(async () => {
    calls += 1;
    return response({ token: 'too-late', expires_at: new Date(time).toISOString() }, 201);
  });
  await assert.rejects(github.createIssue(report, { marker }), (error) => error.code === 'github_invalid_token_response' && !error.ambiguous);
  assert.equal(calls, 1);
});

test('create timeout is ambiguous and never automatically retried', async () => {
  let attempts = 0;
  const github = client(async (url) => {
    if (url.endsWith('/access_tokens')) return tokenResponse();
    attempts += 1;
    throw new Error('network secret details must not escape');
  });
  await assert.rejects(github.createIssue(report, { marker }), (error) => error.ambiguous && error.code === 'github_unreachable' && !String(error).includes('secret'));
  assert.equal(attempts, 1);
});

test('5xx and timeout statuses are ambiguous; explicit rejections are definitive', async () => {
  for (const status of [400, 401, 403, 408, 422, 429, 500, 502, 503]) {
    let attempts = 0;
    const github = client(async (url) => {
      if (url.endsWith('/access_tokens')) return tokenResponse();
      attempts += 1;
      return response({ secret: 'never disclose upstream body' }, status);
    });
    await assert.rejects(github.createIssue(report, { marker }), (error) => error instanceof GithubError && error.status === status && error.ambiguous === (status === 408 || status >= 500) && !String(error).includes('disclose'));
    assert.equal(attempts, 1);
  }
});

test('malformed or mismatched success remains ambiguous', async () => {
  const cases = [
    () => new Response('not json', { status: 201 }),
    () => response(null, 201),
    () => response({ ...issue, html_url: 'https://evil.test/issues/42' }, 201),
    () => response({ ...issue, html_url: `${issue.html_url}?token=x` }, 201),
    () => response({ ...issue, number: '42' }, 201),
    () => response({ ...issue, html_url: 'https://github.com/DVBeckwitt/Other/issues/42' }, 201),
    () => response({ ...issue, pull_request: {} }, 201),
    () => response(issue, 200),
  ];
  for (const next of cases) {
    const github = client(async (url) => url.endsWith('/access_tokens') ? tokenResponse() : next());
    await assert.rejects(github.createIssue(report, { marker }), (error) => error instanceof GithubError && error.ambiguous);
  }
});

test('oversized upstream body is bounded and remains ambiguous', async () => {
  const github = client(async (url) => url.endsWith('/access_tokens') ? tokenResponse() : new Response('x'.repeat(4 * 1024 * 1024 + 1), { status: 201 }));
  await assert.rejects(github.createIssue(report, { marker }), (error) => error.code === 'github_invalid_response' && error.ambiguous);
});

test('findIssue uses direct issue listing and recognizes only complete terminal marker', async () => {
  let lookupUrl;
  const github = client(async (url) => {
    if (url.endsWith('/access_tokens')) return tokenResponse();
    lookupUrl = new URL(url);
    return response([
      { ...issue, number: 8, body: marker },
      { ...issue, number: 9, body: `text\n\n${marker}`, pull_request: {} },
      { ...issue, body: `Description\n\n${marker}\n` },
    ]);
  });
  assert.deepEqual(await github.findIssue(marker, new Date(time).toISOString()), { issueNumber: 42, issueUrl: issue.html_url });
  assert.equal(lookupUrl.pathname, '/repos/DVBeckwitt/Videre/issues');
  assert.equal(lookupUrl.searchParams.get('state'), 'all');
  assert.equal(lookupUrl.searchParams.get('sort'), 'created');
  assert.equal(lookupUrl.searchParams.get('since'), new Date(time - 300_000).toISOString());
});

test('lookup pages are bounded and absence never creates an issue', async () => {
  let pages = 0;
  const github = client(async (url, options) => {
    if (url.endsWith('/access_tokens')) return tokenResponse();
    assert.equal(options.method, 'GET');
    pages += 1;
    return response(Array.from({ length: 100 }, () => ({ body: 'unrelated' })));
  });
  assert.equal(await github.findIssue(marker, new Date(time).toISOString()), null);
  assert.equal(pages, 5);
});

test('malformed lookup response and wrong-repository match fail closed', async () => {
  for (const result of [{ unexpected: true }, [{ ...issue, body: `Report\n\n${marker}`, html_url: 'https://github.com/Other/Project/issues/42' }]]) {
    const github = client(async (url) => url.endsWith('/access_tokens') ? tokenResponse() : response(result));
    await assert.rejects(github.findIssue(marker, new Date(time).toISOString()), GithubError);
  }
});

test('invalid marker and image URL are rejected before network operations', async () => {
  const github = client(() => assert.fail('Must not fetch'));
  await assert.rejects(github.createIssue(report, { marker: 'unsafe' }), (error) => error.code === 'invalid_marker');
  await assert.rejects(github.findIssue(marker, 'invalid'), (error) => error.code === 'invalid_lookup_date');
  await assert.rejects(github.createIssue(report, { marker, imageUrl: 'https://user:password@example.test/a.png' }), (error) => error.code === 'invalid_image_url');
  await assert.rejects(github.createIssue(report, { marker, imageUrl: 'https://example.test/a.png) @everyone' }), (error) => error.code === 'invalid_image_url');
});
