import { createHash } from 'node:crypto';

export const MAX_SCREENSHOT_BYTES = 2 * 1024 * 1024;
export const MAX_BODY_BYTES = 3 * 1024 * 1024;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const allowedReportKeys = new Set(['schemaVersion', 'submissionId', 'kind', 'title', 'description', 'diagnostics', 'screenshot']);
const diagnosticStrings = new Set(['appVersion', 'buildNumber', 'androidVersion', 'deviceModel', 'playerType', 'recoveryPhase']);
const diagnosticBooleans = new Set(['proxyEnabled', 'manualSelection']);
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const crcTable = Uint32Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});

export class InputError extends Error {
  constructor(code = 'invalid_report', status = 400) {
    super(code);
    this.code = code;
    this.status = status;
  }
}
function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
function boundedText(value, max) {
  if (typeof value !== 'string' || !value.trim() || value.length > max || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) throw new InputError();
  return value;
}
function crc32(bytes) {
  let result = 0xffffffff;
  for (const byte of bytes) result = crcTable[(result ^ byte) & 0xff] ^ (result >>> 8);
  return (result ^ 0xffffffff) >>> 0;
}

// Accept a complete, bounded PNG, and remove ancillary metadata before serving.
// Never accept SVG, a remote attachment URL, or a filesystem path from clients.
export function sanitizePng(value) {
  if (!object(value) || Object.keys(value).some(key => !['mimeType', 'base64'].includes(key)) || value.mimeType !== 'image/png' || typeof value.base64 !== 'string') throw new InputError('invalid_screenshot');
  if (value.base64.length > Math.ceil(MAX_SCREENSHOT_BYTES / 3) * 4) throw new InputError('too_large', 413);
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.base64)) throw new InputError('invalid_screenshot');
  const data = Buffer.from(value.base64, 'base64');
  if (data.length > MAX_SCREENSHOT_BYTES || data.length < 57 || !data.subarray(0, 8).equals(pngSignature)) throw new InputError('invalid_screenshot');
  let offset = 8;
  let header = false;
  let imageData = false;
  let ended = false;
  const chunks = [pngSignature];
  while (offset < data.length) {
    if (offset + 12 > data.length) throw new InputError('invalid_screenshot');
    const length = data.readUInt32BE(offset);
    if (length > MAX_SCREENSHOT_BYTES || offset + 12 + length > data.length) throw new InputError('invalid_screenshot');
    const type = data.toString('ascii', offset + 4, offset + 8);
    if (!/^[A-Za-z]{4}$/.test(type) || crc32(data.subarray(offset + 4, offset + 8 + length)) !== data.readUInt32BE(offset + 8 + length)) throw new InputError('invalid_screenshot');
    if (!header && type !== 'IHDR') throw new InputError('invalid_screenshot');
    if (type === 'IHDR') {
      if (header || length !== 13) throw new InputError('invalid_screenshot');
      const width = data.readUInt32BE(offset + 8);
      const height = data.readUInt32BE(offset + 12);
      if (width < 1 || height < 1 || width > 4096 || height > 4096 || width * height > 8388608 || data[offset + 18] !== 0 || data[offset + 19] !== 0 || data[offset + 20] > 1) throw new InputError('invalid_screenshot');
      header = true;
    } else if (type === 'IDAT') {
      imageData = true;
    } else if (type === 'IEND') {
      if (length !== 0 || !imageData || offset + 12 !== data.length) throw new InputError('invalid_screenshot');
      ended = true;
    } else if (type === 'PLTE' || type === 'tRNS') {
      if (imageData) throw new InputError('invalid_screenshot');
    } else if (type[0] === type[0].toUpperCase()) {
      throw new InputError('invalid_screenshot');
    }
    if (['IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'].includes(type)) chunks.push(data.subarray(offset, offset + length + 12));
    offset += length + 12;
  }
  if (!ended) throw new InputError('invalid_screenshot');
  return Buffer.concat(chunks);
}

export function validateReport(input) {
  if (!object(input) || Object.keys(input).some(key => !allowedReportKeys.has(key)) || input.schemaVersion !== 1 || typeof input.submissionId !== 'string' || !UUID.test(input.submissionId) || !['bug', 'suggestion'].includes(input.kind)) throw new InputError();
  const report = {
    schemaVersion: 1,
    submissionId: input.submissionId.toLowerCase(),
    kind: input.kind,
    title: boundedText(input.title, 120),
    description: boundedText(input.description, 8000),
  };
  if (input.diagnostics !== undefined) {
    if (!object(input.diagnostics)) throw new InputError('invalid_diagnostics');
    const diagnostics = {};
    for (const key of Object.keys(input.diagnostics).sort()) {
      const value = input.diagnostics[key];
      if (diagnosticStrings.has(key)) {
        const limit = ['appVersion', 'buildNumber'].includes(key) ? 64 : 120;
        diagnostics[key] = boundedText(value, limit);
        if (/[\r\n\t@]|:\/\//u.test(value)) throw new InputError('invalid_diagnostics');
        if (key === 'playerType' && !['none', 'audio', 'video', 'tv'].includes(value)) throw new InputError('invalid_diagnostics');
        if (key === 'recoveryPhase' && !['trying', 'ready', 'succeeded', 'failed'].includes(value)) throw new InputError('invalid_diagnostics');
      }
      else if (diagnosticBooleans.has(key) && typeof value === 'boolean') diagnostics[key] = value;
      else if (key === 'alternativeCount' && Number.isInteger(value) && value >= 0 && value <= 2) diagnostics[key] = value;
      else throw new InputError('invalid_diagnostics');
    }
    report.diagnostics = diagnostics;
  }
  const image = input.screenshot === undefined ? null : sanitizePng(input.screenshot);
  const hash = createHash('sha256').update(JSON.stringify(report)).update(image ?? Buffer.alloc(0)).digest('hex');
  return { report, image, hash };
}

export function receiptIsValid(receipt, owner, repo) {
  return receipt !== null && typeof receipt === 'object' && Number.isSafeInteger(receipt.issueNumber) && receipt.issueNumber > 0 && receipt.issueUrl === `https://github.com/${owner}/${repo}/issues/${receipt.issueNumber}`;
}
