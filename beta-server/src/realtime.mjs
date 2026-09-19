import { WebSocket, WebSocketServer } from 'ws';
import { randomUUID } from 'node:crypto';

// Audio/transcripts stay in memory. Each admitted stream consumes a beta quota
// slot, including failed streams, to bound provider spend independently of REST.
export function attachRealtime(server, { subjectFrom, limited, countToday, dailyLimit, record, sarvamKey, allowedModes,
  providerURL = 'wss://api.sarvam.ai/speech-to-text-realtime/ws' }) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 6400, perMessageDeflate: false });
  const active = new Set();
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    const subject = subjectFrom(req);
    const reject = status => socket.end(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    if (url.pathname !== '/v1/realtime') return reject(404);
    if (!subject) return reject(401);
    const config = allowedModes.get(url.searchParams.get('mode'));
    if (!config) return reject(400);
    if (!sarvamKey) return reject(503);
    if (active.has(subject) || active.size >= 8 || limited(subject) || countToday(subject) >= dailyLimit) return reject(429);
    wss.handleUpgrade(req, socket, head, client => {
      active.add(subject);
      const id = randomUUID();
      record(subject, 200, id);
      const target = new URL(providerURL);
      Object.entries({ language_code: config[0], mode: config[1], model: 'saaras:v4',
        sample_rate: '16000', encoding: 'linear16', endpointing: 'vad', stream_type: 'balanced',
        silence_duration_ms: '600' }).forEach(([k, v]) => target.searchParams.set(k, v));
      const upstream = new WebSocket(target, { headers: { 'api-subscription-key': sarvamKey },
        handshakeTimeout: 10000, maxPayload: 256 * 1024, perMessageDeflate: false });
      let ready = false, ending = false, done = false, bytes = 0, sequence = 0;
      const started = Date.now();
      let lastAudio = started;
      let finishTimer;
      const send = event => {
        if (client.readyState !== WebSocket.OPEN) return;
        if (client.bufferedAmount > 128 * 1024) return client.terminate();
        client.send(JSON.stringify({ ...event, sequence: ++sequence }));
      };
      const fail = code => {
        if (done) return;
        done = true;
        send({ event: 'error', code, message: 'Live dictation stopped. Release the shortcut and try again.' });
        client.close(1011, code);
        upstream.terminate();
      };
      const timer = setInterval(() => {
        if (Date.now() - started > 120000) fail('session_limit');
        else if (!ready && Date.now() - started > 10000) fail('connection_timeout');
        else if (ready && !ending && Date.now() - lastAudio > 15000) fail('audio_timeout');
      }, 1000);
      client.on('message', (data, binary) => {
        if (done) return;
        if (!ready || ending) return fail('invalid_state');
        if (binary) {
          bytes += data.length;
          lastAudio = Date.now();
          if (!data.length || data.length % 2 || bytes > 120 * 32000 ||
              bytes > ((Date.now() - started) / 1000 + 5) * 32000) return fail('audio_limit');
          if (upstream.bufferedAmount > 128 * 1024) return fail('connection_too_slow');
          upstream.send(JSON.stringify({ event: 'audio_input', audio: data.toString('base64') }));
        } else {
          let event; try { event = JSON.parse(data); } catch { return fail('invalid_message'); }
          if (event.event !== 'end') return fail('invalid_message');
          ending = true;
          upstream.send(JSON.stringify({ event: 'end' }));
          finishTimer = setTimeout(() => fail('finalization_timeout'), 15000);
        }
      });
      upstream.on('message', data => {
        let event; try { event = JSON.parse(data); } catch { return fail('provider_protocol'); }
        if (event.event === 'session.begin') { ready = true; send({ event: 'ready' }); }
        else if (event.event === 'transcript.partial' || event.event === 'transcript.final') {
          if (typeof event.text !== 'string') return fail('provider_protocol');
          send({ event: event.event, text: event.text });
        } else if (event.event === 'session.end') {
          done = true; send({ event: 'done' }); client.close(1000); upstream.close();
        } else if (event.event === 'error') fail('provider_error');
      });
      upstream.on('error', () => fail('provider_connection'));
      upstream.on('close', () => { if (!done) fail('provider_closed'); });
      client.on('error', () => client.terminate());
      client.on('close', () => {
        done = true; clearInterval(timer); clearTimeout(finishTimer);
        active.delete(subject); upstream.terminate();
        console.log(JSON.stringify({ requestId: id, event: 'realtime_closed', audioSeconds: bytes / 32000 }));
      });
    });
  });
  return wss;
}
