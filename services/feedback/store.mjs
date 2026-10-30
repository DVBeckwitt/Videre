import { DatabaseSync } from 'node:sqlite';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export class StoreError extends Error {
  constructor(code, status) { super(code); this.code = code; this.status = status; }
}

/** One service process per database/volume. Report receipts are durable. */
export class FeedbackStore {
  constructor(path, { maxReports = 10000, maxImageBytes = 100 * 1024 * 1024, perIpHour = 5, perDay = 100, perIpMinute = 30, requestsPerMinute = 300 } = {}) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    this.limits = { maxReports, maxImageBytes, perIpHour, perDay, perIpMinute, requestsPerMinute };
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS reports (
        id TEXT PRIMARY KEY, hash TEXT NOT NULL, status TEXT NOT NULL,
        created_at INTEGER NOT NULL, attempted_at INTEGER, reconciled_at INTEGER,
        image_id TEXT UNIQUE, image BLOB,
        issue_number INTEGER, issue_url TEXT
      );
      CREATE TABLE IF NOT EXISTS limits (key TEXT PRIMARY KEY, bucket INTEGER NOT NULL, count INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS limits_age ON limits(bucket);
    `);
    this.db.prepare('INSERT OR IGNORE INTO metadata(key, value) VALUES (?, ?)').run('rate_salt', randomBytes(32).toString('hex'));
    this.rateSalt = this.db.prepare('SELECT value FROM metadata WHERE key = ?').get('rate_salt').value;
  }
  close() { this.db.close(); }
  bindRepository(repository) {
    this.db.prepare('INSERT OR IGNORE INTO metadata(key,value) VALUES (?,?)').run('repository', repository);
    if (this.db.prepare('SELECT value FROM metadata WHERE key=?').get('repository').value !== repository) throw new Error('Feedback database belongs to another repository');
  }
  get(id) { return this.db.prepare('SELECT id, hash, status, created_at, attempted_at, reconciled_at, image_id, issue_number, issue_url FROM reports WHERE id = ?').get(id); }
  receipt(row) { return { status: 'created', issueNumber: row.issue_number, issueUrl: row.issue_url }; }
  identity(ip, now) { return createHmac('sha256', this.rateSalt).update(`${Math.floor(now / 86400000)}:${ip}`).digest('hex'); }
  count(key) { return this.db.prepare('SELECT count FROM limits WHERE key = ?').get(key)?.count ?? 0; }
  increment(key, now) { this.db.prepare('INSERT INTO limits(key,bucket,count) VALUES (?,?,1) ON CONFLICT(key) DO UPDATE SET count=count+1').run(key, now); }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = action(); this.db.exec('COMMIT'); return value; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  allowRequest(ip, now) {
    const minute = Math.floor(now / 60000);
    const identity = this.identity(ip, now);
    return this.transaction(() => {
      this.db.prepare('DELETE FROM limits WHERE bucket < ?').run(now - 172800000);
      const perIp = `request:${minute}:${identity}`;
      const global = `requests:${minute}`;
      if (this.count(perIp) >= this.limits.perIpMinute || this.count(global) >= this.limits.requestsPerMinute) return false;
      this.increment(perIp, now); this.increment(global, now);
      return true;
    });
  }
  claim({ report, image, hash }, ip, now) {
    return this.transaction(() => {
      const existing = this.get(report.submissionId);
      if (existing) {
        if (existing.hash !== hash) throw new StoreError('submission_conflict', 409);
        return { row: existing, fresh: false };
      }
      const totals = this.db.prepare('SELECT COUNT(*) AS count, COALESCE(SUM(length(image)),0) AS image_bytes FROM reports').get();
      if (totals.count >= this.limits.maxReports || totals.image_bytes + (image?.length ?? 0) > this.limits.maxImageBytes) throw new StoreError('unavailable', 503);
      const ipKey = `report:${Math.floor(now / 3600000)}:${this.identity(ip, now)}`;
      const dayKey = `reports:${Math.floor(now / 86400000)}`;
      if (this.count(ipKey) >= this.limits.perIpHour || this.count(dayKey) >= this.limits.perDay) throw new StoreError('rate_limited', 429);
      this.increment(ipKey, now); this.increment(dayKey, now);
      this.db.prepare('INSERT INTO reports(id,hash,status,created_at,image_id,image) VALUES (?,?,?,?,?,?)').run(report.submissionId, hash, 'queued', now, image ? randomUUID() : null, image);
      return { row: this.get(report.submissionId), fresh: true };
    });
  }
  markAttempt(id, now) {
    // Persist BEFORE the external write. A process crash must not permit another
    // create call without reconciling the first one with GitHub.
    return this.db.prepare("UPDATE reports SET status='pending',attempted_at=? WHERE id=? AND status IN ('queued','rejected')").run(now, id).changes === 1;
  }
  markRejected(id, now) {
    this.db.prepare("UPDATE reports SET status='rejected',attempted_at=? WHERE id=?").run(now, id);
  }
  markReconciled(id, now) { this.db.prepare('UPDATE reports SET reconciled_at=? WHERE id=?').run(now, id); }
  markCreated(id, receipt) {
    this.db.prepare("UPDATE reports SET status='created',issue_number=?,issue_url=? WHERE id=?").run(receipt.issueNumber, receipt.issueUrl, id);
  }
  image(id) {
    // A pending image may be fetched by GitHub while its create response is in
    // flight. Unpredictable image IDs are never listed or supplied by clients.
    return this.db.prepare("SELECT image FROM reports WHERE image_id=? AND status IN ('pending','created')").get(id)?.image;
  }
}
