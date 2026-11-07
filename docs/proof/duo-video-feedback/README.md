# Native reader scrolling — video feedback batch

Tracks [#32](https://github.com/saphid/duocord-native/issues/32), based on [toli's Duo video](https://x.com/tolimarchuk/status/2118822655130288363). Baseline: [59bcd5b](https://github.com/saphid/duocord-native/commit/59bcd5b7b2788b6d5e53486d4ff0989d294d6ee1), TestFlight 1.0 (202611070100).

The complete narration was transcribed locally and matched to video frames. The speaker reviews Discord, so its failures are not assumed to exist in Duocord. The original media and full transcription are not republished here.

## Change

A native drag-start callback now releases the message list's Latest pin immediately. Drag-end and deceleration-end callbacks settle the reading state and retain the existing anchor-save behavior. A reader moving into history stays there through the next layout pass; returning to the newest messages resumes following. This avoids depending exclusively on the collection view's `isTracking` flag to recognize reading intent.

The regression mounts the real RootView and message controller, delivers the UIScrollViewDelegate lifecycle, moves 250 points into history, forces layout, and checks both retained position and resumed following. It simulates the delegate sequence; it does not prove that the physical Duo's bar forwards a gesture to this delegate.

## Verification

- Baseline production plus the new regression: three failed assertions, including a 250-point snap back to Latest, real test exit 65.
- Final focused run: 50 passed, zero failed or skipped, exit 0. Includes all adaptive-presentation and composer-continuity tests.
- Full candidate: 687 methods executed; 682 passed, five failed, zero skipped; exit 65. All five failures reproduce on unmodified baseline: seven layout methods executed, two passed, five failed, matching all 11 failed assertions and primary failure messages. See [baseline comparison](baseline-comparison.json). These failures remain unresolved; they are not described as passing tests.
- Release simulator build for arm64 and x86_64 passed, exit 0. All seven invocation-owned DerivedData roots were removed. See [command exits](command-exits.json).
- Fresh independent source review was attempted on Claude Opus 5.5, high effort, through T3. The task failed before review because of the provider's API rate limit. No review findings or approval exist. See [review attempt](review-attempt.json). No CODING_STANDARDS.md was found in this worktree or the repository's primary/public-main worktrees.
- Native visual proof was attempted with GPT-6 Astra, high reasoning, through the T3 Device tools. `device_open` twice returned “No device … on 'This machine'”; the prescribed list refresh omitted the owned proof simulators. The worker stopped. No screenshots or visual verdict were obtained.
- The installed iOS 27.2 runtime rejected creation of an actual iPhone Duo simulator with CoreSimulator error 403, “Incompatible device.” Physical hinge, vertical-bar scrolling and fold transitions remain unverified.

## Remaining video checklist

- 13–22s, hide/reveal the DM sidebar in landscape: Duocord already uses a native split view with a detail-toolbar hide action and system reveal control. Actual visual checks remain pending; two existing sidebar visibility tests fail on both base and candidate.
- 22–33s, adapt around a half-fold: existing book and tabletop layouts remain in place. Adaptive route/composer-state checks pass; hardware and visual proof remain pending.
- 33–48s, overlapping content after rotation: no reproduction in a real Duo runtime was available. This batch makes no layout or toolbar changes and does not claim this complaint fixed.
- 50–59s, preserve keyboard rising to halfway: existing tabletop keyboard/composer code is unchanged. Continuity checks pass; visual tabletop keyboard proof remains pending.
- 72–77s, scroll from the right-edge strip: the native reader-lifecycle snap-back is fixed and tested at the delegate seam. Physical bar routing and the actual gesture remain unverified.

The broad video task remains open in [#32](https://github.com/saphid/duocord-native/issues/32). This is a bounded scrolling release, not a claim that every demonstrated UI issue has been resolved.

## Released

Duocord Native **1.0 (202611070517)** is available to the existing internal TestFlight groups **Alex**, **t3crew** and **DuoCrew**. Independent Apple readback at 2026-11-07T05:22:38Z confirms **VALID / IN_BETA_TESTING**, exact release notes and group assignment. Archive/export, upload and sharing all exited 0; app and extension signatures, bundle/build/team identities, distribution provisioning and all 84 frozen source hashes passed verification. The uploaded IPA and archived executables remained unchanged.

Merged [#33](https://github.com/saphid/duocord-native/pull/33) as [33f1bae](https://github.com/saphid/duocord-native/commit/33f1baefdf2500da9394ec64b1dcc3940d1df39a). Released source is tagged [testflight/202611070517](https://github.com/saphid/duocord-native/tree/testflight%2F202611070517). Manifest SHA-256: `b6f6fd5fabf563c710c92a939b9371251c5c569f8c70fba5b70837094eb3629b`.

See [availability readback](availability-readback.json), [signed artifact checks](archive-verification.json) and [release source](release-source.json). The source-review and UI-verification limits above remain. No live Discord writes, new tester invitations, public beta links or production App Store submission occurred.
