# Vaani closed-beta deployment plan

## Decision record

The Mac mini is approved only for an invite-only beta. It runs the API as a Docker container bound to loopback; Tailscale is the only ingress. `tailscale serve` is for our private testing and `tailscale funnel` is for external TestFlight traffic. A Funnel URL is public, so application authentication, quotas, and rate limiting are required even during beta.

Provider secrets stay in the server `.env`. They must never enter an iOS app bundle, App Group preferences, macOS settings, source control, crash logs, or support screenshots. No router port-forwarding is permitted.

## Rollout

1. Install Docker Desktop and the Tailscale CLI on the Mac mini. Enable FileVault, automatic macOS security updates, Tailscale device approval, and SSH keys only.
2. Copy this repository using a private remote. On the Mac mini create `beta-server/.env` from `.env.example`, generate the signing secret, create a separate capped Sarvam beta key, and create individual invite codes.
3. Start `docker compose up -d --build` from `beta-server`. Confirm only `127.0.0.1:8080` is listening and `curl http://127.0.0.1:8080/healthz` returns `ok`.
4. Use Tailscale Serve first. Enable Funnel only after a request against the Funnel URL reaches the health endpoint. Funnel configuration must be restricted to this one Mac mini node.
5. Migrate both clients to the `/v1/beta/session` and `/v1/transcriptions` API before any external tester is invited. The existing direct Sarvam client is development-only and must not be used by the beta build.
6. Create a TestFlight external group after internal testing. Start with 10 testers, then 25, then 100 only if cost/error/latency thresholds are met.

## Beta operating limits

- Maximum audio payload: 10 MiB. Decoded recording-duration enforcement is required before public launch; beta relies on this payload ceiling and per-user quotas because Apple recorder WAV headers are not reliable until fully finalized.
- Maximum successful transcriptions: 60 per user per UTC day and 20 API requests per minute.
- Audio is held only in request memory and discarded after the upstream request completes. SQLite records a pseudonymous subject, timestamp, status, and request ID only.
- The server applies the model, language mapping, quota, and provider key. Clients cannot select a model or provider key.
- Use a monthly provider budget alert plus a manual kill switch: `tailscale funnel reset`.

## Required monitoring

- A local health check every minute and an external HTTPS health check every five minutes.
- Alerts for failed health checks, Docker restart loops, low disk space, high 5xx/429 rate, and provider spend.
- Capture only request IDs, status, latency, and safe error categories. Never log audio, transcript text, tokens, cookies, or authorization headers.

## Migration to a VPS

The Docker image and API contract remain unchanged. Provision a managed Postgres database, move usage records from SQLite, deploy the container behind a managed HTTPS load balancer, point the stable API hostname at it, rotate all secrets, then disable the Funnel. Public launch additionally requires Sign in with Apple token verification, App Attest, durable distributed rate limiting, privacy/legal review, backups/restore drills, and an incident-response runbook.
