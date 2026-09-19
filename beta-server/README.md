# Vaani beta API

This is the temporary, invite-only backend for the Mac mini beta. It owns the Sarvam key and never writes raw audio to disk. It accepts a short-lived beta session token, enforces an in-memory per-minute limit plus a SQLite daily quota, and records only successful request metadata.

## Before first start

1. Copy `.env.example` to `.env` on the Mac mini; `.env` must never be committed or copied to a client.
2. Generate the session secret: `openssl rand -hex 32`.
3. Create each beta invite code offline. Put its keyed hash in `BETA_INVITE_HASHES` using this exact command, so the server can verify it: `node -e "const c=require('crypto'); console.log(c.createHmac('sha256', process.env.SESSION_SIGNING_SECRET).update(process.argv[1]).digest('hex'))" 'INVITE-CODE'`.
4. Set a dedicated, spending-capped `SARVAM_API_KEY`.
5. Start only after reviewing `compose.yaml`: `docker compose up -d --build`.

The API is intentionally bound to `127.0.0.1:8080`. Do not publish the Docker port or router-port-forward it.

## Tailscale

Use `tailscale serve` while only developers are testing. For external TestFlight users, expose only this listener with `tailscale funnel 8080` after enabling Funnel for the specific Mac mini in the tailnet policy. Funnel is public: authentication and quotas remain mandatory.

## API contract

`POST /v1/beta/session` accepts `{ "inviteCode": "..." }` and returns a 12-hour bearer token. This is beta-only authentication. Replace it with server-verified Sign in with Apple and App Attest before a public launch.

`POST /v1/transcriptions?mode=gujarati` accepts a PCM WAV `file` in `multipart/form-data`; it requires the bearer token. Valid modes are `gujarati`, `gujlish`, `hindi`, `hinglish`, and `english`. The beta enforces its 10 MiB payload cap; decoded-duration enforcement is a production-launch requirement.

## Operations

- `GET /healthz` is safe for a local health check.
- Back up the `vaani_beta_data` Docker volume encrypted; it contains usage metadata, not audio.
- Rotate `SESSION_SIGNING_SECRET` to invalidate all sessions and rotate provider keys if a secret is suspected exposed.
- Stop public ingress immediately with `tailscale funnel reset`; do not stop Docker before collecting the minimal error details needed for diagnosis.

## Explicit beta limitations

The beta token is an invite-only guard, not a customer identity. It does not replace Sign in with Apple, App Attest, durable distributed rate limiting, a managed database, or high availability. Those are launch blockers when moving from the Mac mini to a VPS.
