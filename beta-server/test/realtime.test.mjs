import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { WebSocket, WebSocketServer } from 'ws';
import { attachRealtime } from '../src/realtime.mjs';

const modes = new Map([['gujarati', ['gu-IN', 'transcribe']], ['gujlish', ['gu-IN', 'translit']],
  ['hindi', ['hi-IN', 'transcribe']], ['hinglish', ['hi-IN', 'translit']], ['english', ['en-IN', 'transcribe']]]);

async function fixture(t, overrides = {}) {
  const provider = new WebSocketServer({ port: 0, host: '127.0.0.1' });
  await once(provider, 'listening');
  const server = http.createServer();
  const records = [];
  const relay = attachRealtime(server, { subjectFrom: req => req.headers.authorization === 'Bearer test' ? 'tester' : null,
    limited: () => false, countToday: () => 0, dailyLimit: 60, record: (...args) => records.push(args),
    sarvamKey: 'fake-provider-key', allowedModes: modes,
    providerURL: `ws://127.0.0.1:${provider.address().port}`, ...overrides });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => {
    for (const client of relay.clients) client.terminate();
    for (const client of provider.clients) client.terminate();
    relay.close();
    await Promise.all([new Promise(resolve => server.close(resolve)), new Promise(resolve => provider.close(resolve))]);
  });
  return { provider, records, url: `ws://127.0.0.1:${server.address().port}/v1/realtime` };
}

for (const [mode, config] of modes) test(`streams ${mode}: ordered audio, partials, finals, graceful end`, { timeout: 5000 }, async t => {
  const f = await fixture(t);
  const received = [];
  f.provider.on('connection', (ws, req) => {
    const query = new URL(req.url, 'http://localhost').searchParams;
    assert.equal(query.get('language_code'), config[0]); assert.equal(query.get('mode'), config[1]);
    assert.equal(req.headers['api-subscription-key'], 'fake-provider-key');
    ws.send(JSON.stringify({ event: 'session.begin' }));
    ws.on('message', data => {
      const message = JSON.parse(data); received.push(message);
      if (message.event === 'audio_input') {
        ws.send(JSON.stringify({ event: 'transcript.partial', text: 'hello' }));
      } else if (message.event === 'end') {
        ws.send(JSON.stringify({ event: 'transcript.final', text: 'hello world' }));
        ws.send(JSON.stringify({ event: 'session.end' }));
      }
    });
  });
  const client = new WebSocket(`${f.url}?mode=${mode}`, { headers: { Authorization: 'Bearer test' } });
  const events = [];
  client.on('message', data => {
    const message = JSON.parse(data); events.push(message);
    if (message.event === 'ready') { client.send(Buffer.alloc(3200, 1)); client.send(JSON.stringify({ event: 'end' })); }
  });
  await once(client, 'close');
  assert.deepEqual(events.map(x => x.event), ['ready', 'transcript.partial', 'transcript.final', 'done']);
  assert.deepEqual(events.map(x => x.sequence), [1, 2, 3, 4]);
  assert.deepEqual(received.map(x => x.event), ['audio_input', 'end']);
  assert.equal(Buffer.from(received[0].audio, 'base64').length, 3200);
  assert.equal(f.records.length, 1);
});

test('rejects missing authentication and exhausted quota before provider connection', { timeout: 5000 }, async t => {
  const f = await fixture(t, { countToday: () => 60 });
  for (const [headers, expected] of [[{}, 401], [{ Authorization: 'Bearer test' }, 429]]) {
    const client = new WebSocket(`${f.url}?mode=english`, { headers });
    const status = await new Promise(resolve => {
      client.on('unexpected-response', (_, res) => { res.resume(); client.terminate(); resolve(res.statusCode); });
      client.on('error', () => {});
    });
    assert.equal(status, expected);
  }
  assert.equal(f.records.length, 0);
});

test('provider failure becomes a sanitized error and closes client', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  f.provider.on('connection', ws => {
    ws.send(JSON.stringify({ event: 'error', code: 'secret', message: 'private provider detail' }));
  });
  const client = new WebSocket(`${f.url}?mode=english`, { headers: { Authorization: 'Bearer test' } });
  const events = []; client.on('message', data => events.push(JSON.parse(data)));
  await once(client, 'close');
  assert.equal(events[0].code, 'provider_error');
  assert.ok(!JSON.stringify(events).includes('private provider detail'));
});
