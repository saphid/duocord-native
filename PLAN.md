# Duocord Native — plan

A fully native SwiftUI Discord client for iOS 27, designed first for the
iPhone Duo (foldable). Replaces the WKWebView wrapper in
`/Users/saphid/.t3/projects/duocord` (sibling, "Duocord").

## 1. Principles

- Two size classes, one model. Compact (outer display, Slide Over, narrow
  Split View) and regular (inner display). Pose-specific behaviour only
  where the fold geometry requires it (book: sidebar ends at the fold;
  table-top: interactive controls below the fold).
- All app state lives in `@Observable` models outside the view tree, so a
  fold, rotation, or size-class change rebuilds views without losing the
  selected channel, scroll anchor, composer draft, or call.
- The message list is UIKit (`UICollectionView` with a custom layout fed by
  precomputed, exact heights). No estimated heights, so prepending older
  history and fold relayouts cannot jump. This was the bug that ended the
  web wrapper; it is measured (anchor drift in points, frame hitches).
- Mimic the official web client: same super-properties header the real
  Discord web login used (captured from the login sheet), same gateway
  capabilities shape, normal REST cadence, no automation or self-bot features.

## 2. Architecture

```
SwiftUI views ──► AppModel (@MainActor @Observable)
                    ├── Session (token, user, super-properties)
                    ├── DiscordStore: guilds, folders, channels, threads,
                    │     DMs, users, members, roles, read states,
                    │     voice states, typing, guild settings
                    ├── MessageCenter: per-channel MessageTimeline
                    │     (window of messages, hasMore, load state)
                    ├── Navigation: selection, sheets, per-channel drafts
                    │     and scroll anchors (survive view rebuilds)
                    └── VoiceController ──► VoiceEngine (hidden WKWebView)
                                         └► VoiceActivityController (Live Activity)
Gateway (actor): URLSessionWebSocketTask, zlib-stream inflate, heartbeat,
  identify/resume/reconnect with backoff, op 14 member-list subscriptions.
REST (actor): URLSession, auth + super-properties headers, per-route
  rate-limit buckets, 429 retry, typed endpoints.
Transport protocol: live (Discord) or Mock (deterministic in-process data
  for perf runs and screenshots without touching the real account).
```

Rendering pipeline for messages: `Message` → `MessageRenderModel`
(attributed markdown, mention/emoji attachments, attachment/embed boxes with
sizes from the API's width/height) → `MessageLayout` (exact cell height for
a width + content size category), computed off the main thread and cached by
(message id, edit timestamp, width, text size). Images: ImageIO
downsampling to the display pixel size, Discord media-proxy `width/height`
query to cut bytes, NSCache (cost-limited) + URLCache on disk.

## 3. Module layout (one app target, folders)

```
project.yml
App/            DuocordNativeApp, AppModel, RootView, Settings, risk notice
Discord/        Models, Snowflake, Gateway, REST, Endpoints, SuperProperties,
                Store, MessageCenter, ProtoSettings (guild folders), Mock
Markdown/       Discord markdown parser → AST → NSAttributedString
Features/
  Sidebar/      ServerRail, ChannelList, DMList, folders, unread pills
  Chat/         ChatView, header/toolbar, Composer, typing bar
  MessageList/  MessageListController (UICollectionView), layout, cells,
                height engine, image pipeline
  Members/      member list (lazy guild member list)
  Search/ Pins/ Inbox/ Threads/ Forums/
  Login/        LoginSheet (WKWebView on discord.com/login), Keychain
  Voice/        VoiceController, VoiceEngine (hidden web view), call bar
Platform/       FoldGeometry, fold-aware container, Notifications,
                BackgroundKeepAlive, Badge
Shared/         VoiceActivity attributes, intents, Live Activity views
LiveActivity/   widget extension (reused from sibling)
Tests/          unit tests (markdown, gateway decode, layout anchoring,
                rate limits, proto decode)
scripts/        testflight.sh, asc.mjs, install-device.sh (sibling pattern)
build/          DerivedData, council rounds, perf traces, HANDOFF.md
```

## 4. Discord API surface

Gateway `wss://gateway.discord.gg/?v=10&encoding=json&compress=zlib-stream`:
op 2 Identify (token, captured web properties, capabilities without
client-state v2), op 6 Resume, op 1/11 heartbeat with jitter, op 7/9
reconnect/invalid session, op 3 presence (none sent beyond identify), op 14
lazy guild subscriptions (member list + typing), op 4 never sent by the native
session (voice lives in the engine). Events: READY, READY_SUPPLEMENTAL,
GUILD_CREATE/UPDATE/DELETE, CHANNEL_*, THREAD_* (LIST_SYNC, MEMBERS_UPDATE),
MESSAGE_CREATE/UPDATE/DELETE/DELETE_BULK, MESSAGE_REACTION_*, MESSAGE_ACK,
TYPING_START, GUILD_MEMBER_LIST_UPDATE, PRESENCE_UPDATE (members only),
VOICE_STATE_UPDATE, USER_GUILD_SETTINGS_UPDATE, USER_SETTINGS_PROTO_UPDATE,
RELATIONSHIP_*, SESSIONS_REPLACE (ignored).

REST `https://discord.com/api/v9` (what the web client uses):
`GET users/@me`, `GET channels/{id}/messages?limit=50&before|after|around`,
`GET channels/{id}/messages/pins`, `GET guilds/{id}/messages/search`,
`GET channels/{id}/messages/search` (DMs), `GET users/@me/mentions`,
`GET channels/{id}/threads/search` (forums), `GET channels/{id}/threads/archived/public`,
`POST channels/{id}/messages` (+ `POST channels/{id}/attachments` upload flow),
`POST channels/{id}/typing`, `POST channels/{id}/messages/{mid}/ack`,
`PUT/DELETE channels/{id}/messages/{mid}/reactions/{emoji}/@me`.
Writes are implemented but never exercised against Alex's account (see §7).

Sign-in: WKWebView sheet on `https://discord.com/login` (desktop Safari UA,
as the sibling used), so captcha and 2FA are Discord's own. A document-start
script keeps a reference to `localStorage` before Discord removes it, and
records the `X-Super-Properties` header the page sends. When a token appears
the sheet closes; token + properties go to the Keychain (device-only).
Optional autofill from the sibling's Keychain login item (simulator provisioning
file from 1Password via op-agent).

## 5. Duo layout

| Pose | Layout |
|---|---|
| Outer (compact, 466×678) | `NavigationSplitView` collapses to a stack: servers+channels → chat. Members, pins, search as sheets. Toolbar symbol-only items go into the vertical side bar. |
| Inner landscape (regular, 951×669) | Sidebar (72 pt rail + channel list) + chat + optional member inspector. |
| Inner portrait (regular, 669×951) | Sidebar + chat; members as inspector overlay. |
| Book (vertical division) | Sidebar column width = fold minX, so servers+channels end exactly at the fold and chat fills the other page; member list replaces the channel page while open. |
| Table-top (horizontal division) | Messages above the fold, composer/call controls below it. |
| Split View / Slide Over | Pure size-class adaptation. |

Toolbar (detail column only): system sidebar toggle; Members, Search, Pins,
Threads, Inbox as titled symbol-only items so the system places them in the
vertical bar; channel name as text title.

## 6. Voice decision

Discord has required DAVE (MLS-based E2EE) for every call since March 2026.
Native voice needs the voice gateway, UDP RTP with AEAD transport crypto, Opus,
echo cancellation and libdave (C++, mlspp + OpenSSL/BoringSSL) cross-built for
iOS: weeks of work with crypto-correctness risk. **Chosen: contained fallback.**
A hidden WKWebView loads Discord web only while a call is active, joins and
controls the call through Discord's own UI, and is torn down on leave. The
native gateway sees the account's VOICE_STATE_UPDATE, which drives the native
call bar and the Live Activity (Mute / Deafen / Leave). Details: docs/VOICE.md.

## 7. Safety rules baked in

- First-run risk notice: third-party clients using a user token break
  Discord's terms; Discord can act on the account.
- Testing never sends, edits, reacts or deletes on Alex's account; voice only
  in duocord-test (1565909273286942760). Read acks are a setting
  ("Mark channels read"), off by default in debug builds.
- Token only in Keychain; never logged. Secrets from 1Password only via op-agent
  into a file/child process.

## 8. Performance budgets (simulator, Debug-off Release build)

| Metric | Budget | How measured |
|---|---|---|
| Cold start → cached chat visible | ≤ 700 ms | os_signpost launch→first message frame |
| Channel switch (cached) | ≤ 100 ms | signpost select→first frame |
| Channel switch (network) | ≤ 500 ms + RTT | signpost |
| Prepend older page | 0 pt anchor drift, ≤ 1 hitch | anchor y before/after, CADisplayLink |
| Scroll, 2,000-message image-heavy mock channel | ≥ 99% frames on time at device refresh, no hitch > 1 frame | CADisplayLink hitch counter + `agent-device perf frames` / xctrace |
| Memory, long session | ≤ 250 MB | `agent-device perf memory sample` |

## 9. Risks

1. Account action from Discord (terms). Mitigate: mimic web client, no
   automation; disclose prominently.
2. Gateway READY shape for user accounts is undocumented and changes.
   Mitigate: tolerant decoding (optional fields), log unknowns.
3. Guild folders live in protobuf user settings. Mitigate: minimal wire-format
   decoder for the two fields used; fall back to READY guild order.
4. Simulator limits: 120 Hz, real hinge, table-top, Split View may not be
   reproducible; fold geometry can be faked in debug. Report what was simulated.
5. Hidden web view voice: second session, memory while in a call, Discord DOM
   changes. Contained behind a `VoiceEngine` protocol.
6. Captcha on login in a fresh simulator. Mitigate: real web login sheet.
