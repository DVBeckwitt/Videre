import { createPrivateKey, sign } from 'node:crypto';

const githubApiVersion = '2026-03-10';
const markerPattern = /^<!-- videre-feedback:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12} -->$/i;

/** Carries only a safe code, never upstream bodies, tokens, or request content. */
export class GithubError extends Error {
  constructor(code, { ambiguous = false, status } = {}) {
    super(code);
    this.name = 'GithubError';
    this.code = code;
    this.ambiguous = ambiguous;
    this.status = status;
  }
}

function fencedText(value) {
  const text = String(value);
  const runs = text.match(/`+/g) ?? [];
  const fence = '`'.repeat(Math.max(3, ...runs.map((run) => run.length + 1)));
  return `${fence}text\n${text}\n${fence}`;
}

function issueBody(report, imageUrl, marker) {
  let body = `Submitted from Videre.\n\n## ${report.kind === 'bug' ? 'Bug report' : 'Suggestion'}\n\n${fencedText(report.description)}`;
  if (report.diagnostics != null) {
    body += `\n\n## Optional diagnostics\n\n${fencedText(JSON.stringify(report.diagnostics, null, 2))}`;
  }
  if (imageUrl != null) {
    const image = new URL(imageUrl);
    if (!['https:', 'http:'].includes(image.protocol) || image.username || image.password || image.hash || /[\s()<>]/.test(imageUrl)) {
      throw new GithubError('invalid_image_url');
    }
    body += `\n\n## Optional screenshot\n\n![Screenshot supplied by the reporter](${image.href})`;
  }
  return `${body}\n\n${marker}`;
}

/** GitHub credentials and installation tokens remain exclusively in this service. */
export class GithubIssueClient {
  #owner;
  #repo;
  #appId;
  #installationId;
  #key;
  #fetch;
  #apiBase;
  #timeout;
  #clock;
  #token;
  #tokenExpires = 0;
  #tokenPromise;

  constructor({
    owner,
    repo,
    appId,
    installationId,
    privateKey,
    fetchImpl = fetch,
    apiBase = 'https://api.github.com',
    requestTimeoutMs = 15_000,
    now = Date.now,
  }) {
    this.#owner = owner;
    this.#repo = repo;
    this.#appId = appId;
    this.#installationId = String(installationId ?? '');
    this.#fetch = fetchImpl;
    this.#apiBase = apiBase.replace(/\/$/, '');
    this.#timeout = requestTimeoutMs;
    this.#clock = now;
    try {
      const key = createPrivateKey(privateKey);
      if (key.asymmetricKeyType === 'rsa' && key.asymmetricKeyDetails.modulusLength >= 2048) this.#key = key;
    } catch {
      // Health/configuration checks expose only configured=false.
    }
  }

  get configured() {
    return Boolean(
      /^[A-Za-z0-9][A-Za-z0-9-]{0,38}$/.test(this.#owner ?? '') &&
      /^[A-Za-z0-9_.-]{1,100}$/.test(this.#repo ?? '') &&
      /^[A-Za-z0-9_]{1,128}$/.test(String(this.#appId ?? '')) &&
      /^[1-9][0-9]{0,19}$/.test(this.#installationId) &&
      this.#key &&
      typeof this.#fetch === 'function' &&
      Number.isInteger(this.#timeout) && this.#timeout >= 1 && this.#timeout <= 60_000
    );
  }

  #jwt() {
    const nowSeconds = Math.floor(this.#clock() / 1000);
    const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const input = `${encode({ alg: 'RS256', typ: 'JWT' })}.${encode({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: String(this.#appId) })}`;
    return `${input}.${sign('RSA-SHA256', Buffer.from(input), this.#key).toString('base64url')}`;
  }

  async #request(path, { method = 'GET', body, token, mutation = false } = {}) {
    let response;
    try {
      response = await this.#fetch(`${this.#apiBase}${path}`, {
        method,
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${token}`,
          'X-GitHub-Api-Version': githubApiVersion,
          'User-Agent': 'Videre-Feedback-Service',
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: 'error',
        signal: AbortSignal.timeout(this.#timeout),
      });
    } catch {
      throw new GithubError('github_unreachable', { ambiguous: mutation });
    }
    if (!response.ok) {
      try { await response.body?.cancel(); } catch { /* No body is logged. */ }
      if (response.status === 401) {
        // A revoked/expired token must not poison a later explicit retry.
        this.#token = undefined;
        this.#tokenExpires = 0;
      }
      throw new GithubError('github_rejected', {
        status: response.status,
        ambiguous: mutation && (response.status >= 500 || response.status === 408),
      });
    }
    try {
      const reader = response.body?.getReader();
      if (!reader) throw new Error('missing body');
      const chunks = [];
      let length = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          length += value.byteLength;
          if (length > 4 * 1024 * 1024) throw new Error('response too large');
          chunks.push(value);
        }
      } finally {
        await reader.cancel().catch(() => {});
      }
      return { status: response.status, data: JSON.parse(Buffer.concat(chunks).toString('utf8')) };
    } catch {
      throw new GithubError('github_invalid_response', { ambiguous: mutation });
    }
  }

  async #installationToken() {
    if (!this.configured) throw new GithubError('github_unconfigured');
    if (this.#token && this.#tokenExpires > this.#clock() + 60_000) return this.#token;
    if (!this.#tokenPromise) {
      this.#tokenPromise = (async () => {
        const { data } = await this.#request(`/app/installations/${this.#installationId}/access_tokens`, {
          method: 'POST',
          token: this.#jwt(),
          body: { repositories: [this.#repo], permissions: { issues: 'write' } },
        });
        const expires = Date.parse(data?.expires_at);
        if (typeof data?.token !== 'string' || !data.token || data.token.length > 4096 || !Number.isFinite(expires) || expires <= this.#clock() + 60_000) {
          throw new GithubError('github_invalid_token_response');
        }
        this.#token = data.token;
        this.#tokenExpires = expires;
        return this.#token;
      })();
    }
    try {
      return await this.#tokenPromise;
    } finally {
      this.#tokenPromise = undefined;
    }
  }

  #issueResult(data, ambiguous) {
    const number = data?.number;
    const expected = `https://github.com/${this.#owner}/${this.#repo}/issues/${number}`;
    if (!Number.isSafeInteger(number) || number < 1 || typeof data.html_url !== 'string' || data.html_url.toLowerCase() !== expected.toLowerCase() || data.pull_request != null) {
      throw new GithubError('github_invalid_issue_response', { ambiguous });
    }
    return { issueNumber: number, issueUrl: expected };
  }

  async createIssue(report, { imageUrl, marker }) {
    if (!markerPattern.test(marker)) throw new GithubError('invalid_marker');
    const body = issueBody(report, imageUrl, marker);
    const token = await this.#installationToken();
    const { status, data } = await this.#request(`/repos/${this.#owner}/${this.#repo}/issues`, {
      method: 'POST',
      token,
      mutation: true,
      body: {
        title: `[${report.kind === 'bug' ? 'Bug' : 'Suggestion'}] ${report.title.replace(/@/g, '@\u200b')}`,
        body,
      },
    });
    if (status !== 201) throw new GithubError('github_invalid_issue_response', { ambiguous: true });
    return this.#issueResult(data, true);
  }

  async findIssue(marker, sinceIso) {
    if (!markerPattern.test(marker)) throw new GithubError('invalid_marker');
    const since = Date.parse(sinceIso);
    if (!Number.isFinite(since)) throw new GithubError('invalid_lookup_date');
    const token = await this.#installationToken();
    // List directly instead of relying on delayed GitHub search indexing.
    for (let page = 1; page <= 5; page += 1) {
      const query = new URLSearchParams({ state: 'all', sort: 'created', direction: 'desc', per_page: '100', page: String(page), since: new Date(since - 300_000).toISOString() });
      const { data } = await this.#request(`/repos/${this.#owner}/${this.#repo}/issues?${query}`, { token });
      if (!Array.isArray(data)) throw new GithubError('github_invalid_lookup_response');
      for (const issue of data) {
        if (issue?.pull_request == null && typeof issue?.body === 'string' && issue.body.trimEnd().endsWith(`\n\n${marker}`)) {
          return this.#issueResult(issue, false);
        }
      }
      if (data.length < 100) break;
    }
    return null;
  }
}
