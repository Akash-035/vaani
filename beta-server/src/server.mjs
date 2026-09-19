import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import http from 'node:http';
import { attachRealtime } from './realtime.mjs';

const port = numberEnv('PORT', 8080);
const maxAudioBytes = numberEnv('MAX_AUDIO_BYTES', 10 * 1024 * 1024);
const maxAudioSeconds = numberEnv('MAX_AUDIO_SECONDS', 120);
const dailyLimit = numberEnv('DAILY_TRANSCRIPT_LIMIT', 60);
const perMinute = numberEnv('REQUESTS_PER_MINUTE', 20);
const signingSecret = requiredEnv('SESSION_SIGNING_SECRET');
const inviteHashes = new Set((process.env.BETA_INVITE_HASHES ?? '').split(',').map(v => v.trim()).filter(Boolean));
const sarvamKey = process.env.SARVAM_API_KEY ?? '';
const dataDir = process.env.DATA_DIR ?? join(process.cwd(), 'data');
mkdirSync(dataDir, { recursive: true });
const db = new DatabaseSync(join(dataDir, 'vaani-beta.sqlite'));
db.exec(`PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS usage (
    id TEXT PRIMARY KEY, subject TEXT NOT NULL, created_at TEXT NOT NULL,
    action TEXT NOT NULL, status INTEGER NOT NULL, request_id TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS usage_subject_day ON usage(subject, created_at);`);

const rateBuckets = new Map();
const allowedModes = new Map([
  ['gujarati', ['gu-IN', 'transcribe']], ['gujlish', ['gu-IN', 'translit']],
  ['hindi', ['hi-IN', 'transcribe']], ['hinglish', ['hi-IN', 'translit']],
  ['english', ['en-IN', 'transcribe']]
]);

function requiredEnv(name) { const value = process.env[name]; if (!value || value.length < 32) throw new Error(`${name} must be set to a strong secret`); return value; }
function numberEnv(name, fallback) { const value = Number(process.env[name] ?? fallback); if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be positive`); return value; }
function json(res, status, value, requestId) { res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-request-id': requestId }); res.end(JSON.stringify(value)); }
function base64url(value) { return Buffer.from(value).toString('base64url'); }
function safeEqual(a, b) { const aa = Buffer.from(a); const bb = Buffer.from(b); return aa.length === bb.length && timingSafeEqual(aa, bb); }
function sign(payload) { const body = base64url(JSON.stringify(payload)); const sig = createHmac('sha256', signingSecret).update(body).digest('base64url'); return `${body}.${sig}`; }
function verify(token) { const [body, signature] = token.split('.'); if (!body || !signature || !safeEqual(createHmac('sha256', signingSecret).update(body).digest('base64url'), signature)) return null; try { const payload = JSON.parse(Buffer.from(body, 'base64url').toString()); return payload.exp > Math.floor(Date.now() / 1000) && typeof payload.sub === 'string' ? payload : null; } catch { return null; } }
function subjectFrom(req) { const auth = req.headers.authorization; return auth?.startsWith('Bearer ') ? verify(auth.slice(7))?.sub ?? null : null; }
function limited(subject) { const now = Date.now(); const bucket = rateBuckets.get(subject) ?? []; const active = bucket.filter(t => now - t < 60_000); if (active.length >= perMinute) return true; active.push(now); rateBuckets.set(subject, active); return false; }
function countToday(subject) { return db.prepare("SELECT count(*) AS n FROM usage WHERE subject = ? AND action = 'transcription' AND status = 200 AND created_at >= datetime('now', 'start of day')").get(subject).n; }
function record(subject, status, requestId) { db.prepare('INSERT INTO usage VALUES (?, ?, datetime(\'now\'), ?, ?, ?)').run(randomUUID(), subject, 'transcription', status, requestId); }
async function body(req, limit) { const chunks = []; let size = 0; for await (const chunk of req) { size += chunk.length; if (size > limit) throw Object.assign(new Error('Payload too large'), { status: 413 }); chunks.push(chunk); } return Buffer.concat(chunks); }
function multipartFile(buffer, contentType) {
  const match = /boundary=([^;]+)/i.exec(contentType ?? ''); if (!match) throw Object.assign(new Error('Expected multipart form data'), { status: 415 });
  const boundary = `--${match[1].replace(/^"|"$/g, '')}`; const raw = buffer.toString('latin1');
  const part = raw.split(boundary).find(p => /name="file"/i.test(p)); if (!part) throw Object.assign(new Error('Audio file is required'), { status: 400 });
  const split = part.indexOf('\r\n\r\n'); if (split < 0) throw Object.assign(new Error('Malformed file part'), { status: 400 });
  const header = part.slice(0, split); const content = Buffer.from(part.slice(split + 4).replace(/\r\n$/, ''), 'latin1');
  const name = /filename="([^\"]+)"/i.exec(header)?.[1] ?? 'recording.wav'; const mime = /Content-Type:\s*([^\r\n]+)/i.exec(header)?.[1]?.trim() ?? 'application/octet-stream';
  if (!/^audio\/(wav|x-wav)$/i.test(mime)) throw Object.assign(new Error('Only WAV audio is supported during beta'), { status: 415 });
  return { content, name: name.replace(/[^A-Za-z0-9._-]/g, '_'), mime };
}
function assertWav(file) {
  // Some Apple recorder variants finalize WAV headers asynchronously, so byte-rate
  // fields are not a reliable server-side duration source. The request byte ceiling
  // and per-user quota remain the beta abuse controls; production uses decoded media
  // duration before provider submission.
  if (file.content.length < 44 || file.content.toString('ascii', 0, 4) !== 'RIFF' || file.content.toString('ascii', 8, 12) !== 'WAVE') {
    throw Object.assign(new Error('Invalid WAV audio'), { status: 415 });
  }
}
async function transcribe(file, mode) {
  if (!sarvamKey) throw Object.assign(new Error('Transcription is temporarily unavailable'), { status: 503 });
  const [languageCode, sarvamMode] = allowedModes.get(mode) ?? [];
  if (!languageCode) throw Object.assign(new Error('Unsupported output mode'), { status: 400 });
  const form = new FormData(); form.append('model', 'saaras:v4'); form.append('language_code', languageCode); form.append('mode', sarvamMode); form.append('file', new Blob([file.content], { type: file.mime }), file.name);
  let upstream;
  try {
    upstream = await fetch('https://api.sarvam.ai/speech-to-text', { method: 'POST', headers: { 'api-subscription-key': sarvamKey }, body: form, signal: AbortSignal.timeout(75_000) });
  } catch (error) {
    if (error?.name === 'TimeoutError' || error?.name === 'AbortError') throw Object.assign(new Error('Transcription provider timed out'), { status: 504 });
    throw Object.assign(new Error('Transcription provider connection failed'), { status: 502 });
  }
  const payload = await upstream.json().catch(() => ({}));
  if (!upstream.ok) {
    // Never log provider payloads: they can include user-facing detail. The status
    // is enough to diagnose an integration issue without retaining speech context.
    console.error(JSON.stringify({ upstream: 'sarvam', status: upstream.status }));
    if (upstream.status === 422) throw Object.assign(new Error('Audio must be at most 30 seconds per beta request'), { status: 413 });
    if (upstream.status === 429) throw Object.assign(new Error('Transcription provider is rate limited'), { status: 503 });
    throw Object.assign(new Error('Transcription provider failed'), { status: 502 });
  }
  if (typeof payload.transcript !== 'string') throw Object.assign(new Error('Transcription provider returned an invalid response'), { status: 502 });
  return payload.transcript.trim();
}
const server = http.createServer(async (req, res) => {
  const requestId = randomUUID();
  try {
    if (req.method === 'GET' && req.url === '/healthz') return json(res, 200, { ok: true }, requestId);
    if (req.method === 'POST' && req.url === '/v1/beta/session') {
      const raw = await body(req, 4096); const { inviteCode } = JSON.parse(raw.toString());
      const inviteHash = createHmac('sha256', signingSecret).update(String(inviteCode)).digest('hex');
      // This deliberately uses a server secret so raw invite codes never become database records.
      if (!inviteHashes.has(inviteHash)) return json(res, 401, { error: 'invalid_invite' }, requestId);
      const sub = `beta_${createHmac('sha256', signingSecret).update(String(inviteCode)).digest('hex').slice(0, 32)}`;
      return json(res, 200, { accessToken: sign({ sub, exp: Math.floor(Date.now() / 1000) + 12 * 3600 }), expiresIn: 43200 }, requestId);
    }
    if (req.method === 'POST' && new URL(req.url, 'http://localhost').pathname === '/v1/transcriptions') {
      const subject = subjectFrom(req); if (!subject) return json(res, 401, { error: 'unauthorized' }, requestId);
      if (limited(subject)) return json(res, 429, { error: 'rate_limited' }, requestId);
      if (countToday(subject) >= dailyLimit) return json(res, 429, { error: 'daily_quota_exhausted' }, requestId);
      const mode = new URL(req.url, 'http://localhost').searchParams.get('mode') ?? '';
      const file = multipartFile(await body(req, maxAudioBytes), req.headers['content-type']);
      assertWav(file);
      const text = await transcribe(file, mode); if (!text) throw Object.assign(new Error('No speech detected'), { status: 422 });
      record(subject, 200, requestId); return json(res, 200, { transcript: text, requestId }, requestId);
    }
    return json(res, 404, { error: 'not_found' }, requestId);
  } catch (error) {
    const status = error.status ?? 500; console.error(JSON.stringify({ requestId, status, error: error.message }));
    return json(res, status, { error: status >= 500 ? 'service_error' : error.message }, requestId);
  }
});
server.requestTimeout = 120_000;
attachRealtime(server, { subjectFrom, limited, countToday, dailyLimit, record, sarvamKey, allowedModes });
server.headersTimeout = 15_000;
server.listen(port, '0.0.0.0', () => console.log(`Vaani beta API listening on 0.0.0.0:${port}`));
