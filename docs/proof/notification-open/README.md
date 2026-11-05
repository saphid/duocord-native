# Notification opening crash

The Swift-generated Objective-C wrapper for the async notification-response delegate completed on a concurrency thread. The TestFlight crash stack reached that wrapper through UIKit and `NSAssertionHandler`. The completion-handler entry point now awaits response handling and completes on the main actor.

Verification on 2026-11-05 with Xcode 27.2 / iOS 27.2:

- Base service plus the new delegate regression: exit 65; one executed test failed because both completions ran off main (`[false, false]`).
- Fixed full offline suite: exit 0; 680 passed, one iPad-only layout test skipped, zero failures. The delegate regression passed and only the default action opened the tapped message.
- The regression calls the real Objective-C delegate entry point with system notification objects; it covers the wrapper boundary missed by direct `handle` tests. Its Mark as Read fixture is refused, so it does not prove a suspended write.
- Independent Codex / GPT-6.1 Sol review on high completed with APPROVE and no actionable findings in the two-file behavior/test diff against `5a54adb`. One sol-loop round; no review changes. Task request: `notification-crash-sol-review-r1-20261105`. Usage was not exposed.
- Base simulator installation and mock launch succeeded. Actual banner-tap proof was blocked after notification permission failed twice with `Operation not permitted; Failed to create TCC authorization record`. Device interaction stopped. No screenshot or real tap is claimed.

Local evidence: `/tmp/duocord-notification-open-proof/red.xcresult`, `green-full.xcresult`, and `runtime/runtime-status.json`. TestFlight crash reports remain private.
