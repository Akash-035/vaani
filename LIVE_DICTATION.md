# Mac live dictation beta

Enable Settings → Transcription provider → Vaani Cloud, then Live dictation.
The existing beta session and endpoint are reused. Hold the normal dictation
shortcut in an editable field, speak, and release to finalize. The default
completed-recording path remains available by switching Live dictation off.

## Deploy

On the work account, in the existing checkout:

```sh
cd /Users/work/vaani-repo
git pull --ff-only
cd beta-server
docker compose up -d --build
```

Build/run the Mac target in Xcode. Start testing in TextEdit with an empty
selection. Accessibility and microphone permissions must be enabled for the
app being run. Tailscale Serve continues proxying port 8080, including the
new `/v1/realtime` WebSocket upgrade.

## Behavior and limits

- 100 ms packets of 16 kHz mono PCM; no audio recording file in live mode.
- Beta bearer authentication; provider credentials stay on the server.
- Server uses Saaras v4 realtime, balanced partials, VAD phrase detection.
- Each admitted stream consumes one existing daily beta quota slot (even on
  failure). One stream per beta subject, eight globally, two minutes per stream.
- Ordered bounded queues, partial replacement, final phrase accumulation, and
  an explicit end/completion handshake. Network failure preserves the latest
  preview in the Mac app; audio is not silently replayed.
- Direct insertion requires readable text and writable Accessibility ranges.
  Only an empty initial selection is supported. A changed value, cursor, or
  focused field stops further insertion. Unsupported editors show the overlay;
  copy the result from History. Password fields are excluded from direct insertion.
- Gujlish/Hinglish partials are locally transliterated; provider final spellings
  can differ. All five output modes are exposed for empirical language testing.
- Editor updates are coalesced every 120 ms (250 ms for Gujlish/Hinglish).
  Romanized drafts hold the trailing word until more context or a final arrives.
  Final phrases render immediately and are protected from subsequent corrections.
  Unchanged text produces no Accessibility write. New suffixes append at the
  existing caret without selection; corrections replace only the changed
  grapheme-aligned range. Some editors may still briefly highlight a correction.

## Real-device acceptance checks (not yet verified)

Test Gujarati, Gujlish, Hindi, Hinglish, and English separately: short phrases,
pauses, and a 45-second utterance. Confirm words appear before release, earlier
phrases remain, and release does not duplicate the result. Repeat in Notes,
browser inputs, and messaging editors; record which allow direct insertion.
Move the cursor, change apps, and type manually during speech: insertion must
stop without deleting user text. Disconnect Tailscale: preview must survive and
a new dictation must be possible after reconnecting. Test silence and immediate
shortcut release, plus session expiry. No language-quality claim is made from
the mock integration tests.

References: https://docs.sarvam.ai/api/api-guides-tutorials/speech-to-text/realtime-streaming
and https://developer.apple.com/documentation/foundation/urlsessionwebsockettask
