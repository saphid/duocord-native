# Voice in Duocord Native: decision record

**Chosen: a contained fallback.** Voice runs in a hidden WKWebView that loads
Discord's own web client only while a call is active
(`Features/Voice/VoiceEngine.swift`). Everything the person sees is native: the
call bar, the voice channel bar, participant lists and the Live Activity with
Mute / Deafen / Leave. Call state comes from the native gateway's
`VOICE_STATE_UPDATE` events for this account, not from the web page.

## Why not native voice

Native voice would need all of:

1. Discord's voice gateway (WebSocket, v8 opcodes) and UDP IP discovery.
2. RTP media with Discord's AEAD transport encryption
   (`aead_aes256_gcm_rtpsize` / `aead_xchacha20_poly1305_rtpsize`).
3. Opus encode/decode, jitter buffer, echo cancellation (AVAudioEngine voice
   processing can cover the last part).
4. **DAVE**, Discord's end-to-end encryption for audio and video: MLS
   (RFC 9420) group key agreement plus per-frame encryption. Discord made DAVE
   mandatory for every call (DMs, group DMs, voice channels, Go Live; not
   Stage) from 1–2 March 2026; clients without it can no longer join calls.
   The reference implementation, `discord/libdave` (MIT, C++ and JS), depends
   on an MLS library (mlspp) and OpenSSL/BoringSSL. Shipping it on iOS means
   cross-building that C++ stack, binding its C API, and keeping it in step
   with protocol versions Discord may change.

That is weeks of work with real cryptographic-correctness risk, for a feature
the web client already implements correctly. Sources:
- https://discord.com/blog/bringing-dave-to-all-discord-platforms
- https://discord.com/blog/every-voice-and-video-call-on-discord-is-now-end-to-end-encrypted
- https://github.com/discord/libdave
- https://daveprotocol.com

## How the fallback is contained

- Created lazily when the person taps **Join Voice**, destroyed after Leave
  (1.5 s grace so the page can send its disconnect).
- Non-persistent website data store; the token is set in the page's
  localStorage at document start and nothing persists between calls.
- Navigation is locked to `discord.com`; only `discord.com` may use the
  microphone; the view takes no input and is hidden from accessibility.
- It is inserted at the back of the key window (behind all app views) so
  WebKit keeps audio running.
- Debug builds can only join Alex's test channel `duocord-test`
  (1565909273286942760).

## Costs and limits

- A second Discord session (shows as a web session) exists during a call.
- Extra memory while a call is active (Discord web, roughly 150–300 MB).
- Joining, muting and leaving click Discord's own controls, so a Discord web
  redesign can break them; the native UI keeps reflecting the true state from
  the gateway either way.
- Upgrade path: replace `VoiceEngine` with a libdave-based engine behind the
  same `join / toggleMute / toggleDeafen / leave` surface.
