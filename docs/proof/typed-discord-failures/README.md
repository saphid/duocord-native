# Structured Discord failures

Implements [#34](https://github.com/saphid/duocord-native/issues/34), applying the useful error-model idea from [Rhys Sullivan’s post](https://x.com/rhyssullivan/status/2118584878329643025). The linked [effect-discord-perms](https://github.com/RhysSullivan/effect-discord-perms) is an unreviewed TypeScript bot library. This change independently implements the idea in the existing Swift transport; no library code or dependency was added.

DiscordREST previously discarded Discord’s numeric error code. HTTP403 Missing Access, Missing Permissions and Cannot Message User therefore lost distinctions that callers could use. The transport now preserves HTTP status, numeric code and raw message, and exposes five named refusal reasons with conservative user-facing explanations: missing access50001, missing permissions50013, cannot message user50007, unknown channel10003 and unknown message10008. Meanings were checked against [Discord’s documentation](https://github.com/discord/discord-api-docs/blob/main/developers/topics/opcodes-and-status-codes.mdx#json-json-error-codes).

Generic50013 does not identify a particular missing permission. No preflight or compile-time guarantee of server permission was added: cached state can be stale. Unknown codes retain their number and server message. Malformed fields decode independently; malformed payloads retain the HTTP status fallback. Server5xx responses remain uncertain even when they contain a familiar refusal code.

The existing no-automatic-write-retry and uncertain-outcome behavior remain. Coded403/404 failures retain Inbox access feedback. Pins use the old list only for an actual generic unknown-route404 on the first page; a channel code cannot cause that fallback even with the same text.

## Verification

- Genuine red regression on unchanged production: one test method, three failed user-feedback assertions, exit65.
- First focused run:163 passed, one failed. The failure was an existing unknown-member error-string assertion; it was updated to include the preserved numeric code.
- Final focused run:166 passed, zero failed/skipped, exit0. Real REST transport runs over an offline URLProtocol, covering codes with identical HTTP statuses, raw-code retention, unknown/malformed responses, server ambiguity, sign-out, existing rate limits, one-shot writes, Inbox feedback, pins compatibility and optimistic reaction rollback without an uncertainty read.
- All three invocation-owned DerivedData roots were removed. See [command exits](command-exits.json) and [verification counts](verification.json).
- Fresh independent review through claudeAgent / claude-opus-5-5 / high failed before review at the provider API rate limit. No independent findings or approval exist. See [attempt receipt](review-attempt.json). No CODING_STANDARDS.md was found in the changed paths, current worktree or repository primary.
- Full suite was not rerun for this bounded transport batch. The preceding release’s full suite had five known layout failures, documented in [Duo evidence](../duo-video-feedback/README.md).
- No live Discord operations or new visual verification occurred. The earlier Duo sidebar/fold/rotation/bar-gesture task remains open in [#32](https://github.com/saphid/duocord-native/issues/32).

## Released

Duocord Native **1.0 (202611070623)** is available to the existing internal TestFlight groups Alex, t3crew and DuoCrew. Apple independently reports VALID / IN_BETA_TESTING with exact release notes and group assignments. Archive/export, upload and sharing exited0. Both exported distribution identities/signatures and all84 frozen inputs passed verification; IPA and archived executables remained unchanged after upload. All four invocation-owned DerivedData roots (three tests, one archive) were removed.

Merged [#35](https://github.com/saphid/duocord-native/pull/35) as [6561b26](https://github.com/saphid/duocord-native/commit/6561b26e45653e3ff24c6aba3ed513c3006b5c32). Exact release source is tagged [testflight/202611070623](https://github.com/saphid/duocord-native/tree/testflight%2F202611070623). Manifest SHA256: `abe9a055964efc08ba8329fc150fb5782c539382b68d14d3d5297c7b3cf3e4e5`.

See [availability](availability-readback.json), [source](release-source.json), [manifest](source-manifest.sha256) and [signed artifact checks](archive-verification.json). No production App Store submission, new tester invitation or public beta link was created. Independent-review and Duo visual-verification limits above remain.
