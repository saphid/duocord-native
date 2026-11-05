# Notification opening crash

The Swift-generated Objective-C wrapper for the async notification-response delegate completed on a concurrency thread. The TestFlight crash stack reached that wrapper through UIKit and `NSAssertionHandler`. The completion-handler entry point now awaits response handling and completes on the main actor.

Verification on 2026-11-05 with Xcode 27.2 / iOS 27.2:

- Base service plus the new delegate regression: exit 65; one executed test failed because both completions ran off main (`[false, false]`).
- Fixed full offline suite: exit 0; 680 passed, one iPad-only layout test skipped, zero failures. The delegate regression passed and only the default action opened the tapped message.
- The regression calls the real Objective-C delegate entry point with system notification objects; it covers the wrapper boundary missed by direct `handle` tests. Its Mark as Read fixture is refused, so it does not prove a suspended write.
- Independent Codex / GPT-6.1 Sol review on high completed with APPROVE and no actionable findings in the two-file behavior/test diff against [5a54adb](https://github.com/saphid/duocord-native/commit/5a54adb1abf3bd3020aa9a49cb117c738cdf2112). One sol-loop round; no review changes. The full task ID, actual provider/model, completed status and findings are in [review.json](review.json). Usage was not exposed.
- Base simulator installation and mock launch succeeded. Actual banner-tap proof was blocked after notification permission failed twice with `Operation not permitted; Failed to create TCC authorization record`. Device interaction stopped. No screenshot or real tap is claimed.

Local evidence is preserved under `build/verification/notification-open/`: `red.xcresult`, `green-full.xcresult`, `summary.json`, logs and `runtime-status.json`. TestFlight crash reports remain private.

## TestFlight delivery

Delivered version **1.0 (202611050134)**. Apple independently read back `VALID` and `IN_BETA_TESTING`, with the exact release notes and both existing internal groups assigned. Archive/upload and sharing each exited 0; app and extension identities, build numbers and signatures verified. The owned DerivedData directory was removed.

The fix merged in [#28](https://github.com/saphid/duocord-native/pull/28) as [802adf1](https://github.com/saphid/duocord-native/commit/802adf171920009a048d8b6c7188921b88a87b05). Release source is tagged [testflight/202611050134](https://github.com/saphid/duocord-native/tree/testflight%2F202611050134). All 84 frozen source inputs match [source-manifest.sha256](source-manifest.sha256), whose SHA-256 is `00cebda111f8542eb6b3dcad767cd5537fae1bea054347b66a94a8c9955339a0`. The receipt commit changes only release documentation.

See [availability-readback.json](availability-readback.json), [identity-verification.json](identity-verification.json) and [source.json](source.json). The unrelated dirty primary checkout was preserved; this release uses merged `main` plus this focused fix.
