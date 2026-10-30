import { existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseEnv } from 'node:util';
import { GithubIssueClient } from './github.mjs';
import { startFromEnvironment } from './server.mjs';

const repositoryRoot = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const minimumNode = readFileSync(new URL('.node-version', import.meta.url), 'utf8').trim();
const keys = new Set(['PUBLIC_BASE_URL', 'GITHUB_OWNER', 'GITHUB_REPO', 'GITHUB_APP_ID', 'GITHUB_INSTALLATION_ID', 'GITHUB_PRIVATE_KEY_FILE', 'FEEDBACK_DB', 'HOST', 'PORT', 'PROXY_MODE', 'TRUSTED_PROXY_ADDRESSES', 'TRUSTED_PROXY_HEADER']);

export class LocalConfigurationError extends Error {
  constructor(code) { super(code); this.name = 'LocalConfigurationError'; }
}
function fail(code) { throw new LocalConfigurationError(code); }

export function checkNodeVersion(version = process.versions.node) {
  const parts = version.split('.').map(Number);
  const minimum = minimumNode.split('.').map(Number);
  if (parts.length !== 3 || parts.some(n => !Number.isInteger(n) || n < 0) || parts[0] !== minimum[0] || parts[1] < minimum[1] || (parts[1] === minimum[1] && parts[2] < minimum[2])) fail('unsupported_node_version');
}

export function defaultConfigPath({ platform = process.platform, localAppData = process.env.LOCALAPPDATA, home = homedir() } = {}) {
  if (platform === 'win32') {
    if (!localAppData || !isAbsolute(localAppData)) fail('local_app_data_unavailable');
    return join(localAppData, 'VidereFeedback', 'feedback.env');
  }
  return join(home, '.local', 'share', 'videre-feedback', 'feedback.env');
}

// Resolve existing parent links as well as lexical paths: a junction must not
// accidentally put secrets or SQLite inside a checkout.
function canonicalPath(path) {
  let parent = path;
  while (true) {
    try { lstatSync(parent); break; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const next = dirname(parent);
    if (next === parent) fail('path_unavailable');
    parent = next;
  }
  return resolve(realpathSync(parent), relative(parent, path));
}
function outsideRepository(path) {
  if (typeof path !== 'string' || !isAbsolute(path)) fail('absolute_path_required');
  const full = canonicalPath(resolve(path));
  const root = canonicalPath(repositoryRoot);
  const rel = relative(root, full);
  if (rel === '' || (!isAbsolute(rel) && rel !== '..' && !rel.startsWith(`..${sep}`))) fail('path_inside_repository');
  // Also exclude another checkout of this project (or any other Git checkout).
  for (let parent = full; ; parent = dirname(parent)) {
    if (existsSync(join(parent, '.git'))) fail('path_inside_repository');
    if (dirname(parent) === parent) break;
  }
  return full;
}

export function initializeLocalConfig(configPath = defaultConfigPath()) {
  checkNodeVersion();
  const file = outsideRepository(configPath);
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const template = `# Local Videre feedback configuration. Keep this file and the RSA key private.
# Use a stable HTTPS origin. No service is usable until all required values exist.
PUBLIC_BASE_URL=
GITHUB_OWNER=DVBeckwitt
GITHUB_REPO=Videre
GITHUB_APP_ID=
GITHUB_INSTALLATION_ID=
GITHUB_PRIVATE_KEY_FILE=
# Blank uses data/feedback.sqlite beside this configuration, never the shell cwd.
FEEDBACK_DB=
HOST=127.0.0.1
PORT=8787
# Set cloudflare only for a Cloudflare Tunnel forwarding to http://127.0.0.1:8787.
PROXY_MODE=none
# Managed by PROXY_MODE in this launcher; leave both values blank.
TRUSTED_PROXY_ADDRESSES=
TRUSTED_PROXY_HEADER=
`;
  try { writeFileSync(file, template, { flag: 'wx', mode: 0o600 }); }
  catch (error) { if (error.code === 'EEXIST') fail('configuration_already_exists'); throw error; }
  return file;
}

export function readLocalConfiguration(configPath = defaultConfigPath()) {
  checkNodeVersion();
  const file = outsideRepository(configPath);
  if (!existsSync(file)) fail('configuration_missing');
  if (!statSync(file).isFile() || statSync(file).size > 64 * 1024) fail('configuration_invalid');
  // A dedicated object deliberately excludes inherited HOST, PORT, credential,
  // and proxy environment variables from this launcher's effective service env.
  const values = parseEnv(readFileSync(file, 'utf8'));
  if (Object.keys(values).some(key => !keys.has(key))) fail('unknown_configuration_key');
  if ((values.HOST || '127.0.0.1') !== '127.0.0.1') fail('loopback_host_required');
  const proxyMode = values.PROXY_MODE || 'none';
  if (!['none', 'cloudflare'].includes(proxyMode)) fail('proxy_mode_invalid');
  if (values.TRUSTED_PROXY_ADDRESSES || values.TRUSTED_PROXY_HEADER) fail('proxy_trust_managed_by_proxy_mode');
  const port = values.PORT || '8787';
  if (!/^\d{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65535) fail('port_invalid');
  let origin;
  try { origin = new URL(values.PUBLIC_BASE_URL); } catch { fail('https_origin_required'); }
  if (origin.protocol !== 'https:' || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) fail('https_origin_required');
  if (!values.GITHUB_APP_ID || !values.GITHUB_INSTALLATION_ID) fail('github_ids_required');
  if (!values.GITHUB_PRIVATE_KEY_FILE) fail('github_key_required');
  const keyFile = outsideRepository(values.GITHUB_PRIVATE_KEY_FILE);
  let key;
  try {
    if (!statSync(keyFile).isFile() || statSync(keyFile).size > 64 * 1024) fail('github_key_invalid');
    key = readFileSync(keyFile, 'utf8');
  } catch { fail('github_key_unavailable'); }
  const owner = values.GITHUB_OWNER || 'DVBeckwitt';
  const repo = values.GITHUB_REPO || 'Videre';
  const github = new GithubIssueClient({ owner, repo, appId: values.GITHUB_APP_ID, installationId: values.GITHUB_INSTALLATION_ID, privateKey: key });
  if (!github.configured) fail('github_configuration_invalid');
  const database = outsideRepository(values.FEEDBACK_DB || join(dirname(file), 'data', 'feedback.sqlite'));
  if (database === file || database === keyFile) fail('database_path_conflicts');
  if (existsSync(database) && !statSync(database).isFile()) fail('database_path_invalid');
  return {
    PUBLIC_BASE_URL: origin.origin,
    GITHUB_OWNER: owner,
    GITHUB_REPO: repo,
    GITHUB_APP_ID: values.GITHUB_APP_ID,
    GITHUB_INSTALLATION_ID: values.GITHUB_INSTALLATION_ID,
    GITHUB_PRIVATE_KEY_FILE: keyFile,
    FEEDBACK_DB: database,
    HOST: '127.0.0.1',
    PORT: port,
    TRUSTED_PROXY_ADDRESSES: proxyMode === 'cloudflare' ? '127.0.0.1' : '',
    TRUSTED_PROXY_HEADER: proxyMode === 'cloudflare' ? 'cf-connecting-ip' : 'x-real-ip',
  };
}

export function startLocalService(configPath = defaultConfigPath()) {
  return startFromEnvironment(readLocalConfiguration(configPath));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const [command, configPath, ...extra] = process.argv.slice(2);
    if (extra.length || !['init', 'check', 'start'].includes(command)) fail('usage_node_local_mjs_init_check_start_optional_absolute_config_path');
    if (command === 'init') {
      initializeLocalConfig(configPath);
      process.stdout.write('Local configuration created. Fill the required values before check or start. Nothing is running.\n');
    } else if (command === 'check') {
      readLocalConfiguration(configPath);
      process.stdout.write('Local configuration is structurally ready. GitHub permissions and public HTTPS reachability have not been tested. Nothing is running.\n');
    } else {
      startLocalService(configPath);
      process.stdout.write('Running in the foreground on loopback. Ctrl+C stops the service. No public tunnel or automatic startup was created.\n');
    }
  } catch (error) {
    process.stderr.write(`Local feedback setup: ${error instanceof LocalConfigurationError ? error.message : 'configuration_invalid_or_unavailable'}.\n`);
    process.exitCode = 1;
  }
}
