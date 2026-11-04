# Thread collapse and menus verification

Channel disclosure hides every nested thread, including selected, unread and mentioned rows, while preserving the conversation selection. Shared thread menus cover sidebar rows, active/archived thread lists, forum posts and the chat header. Thread notification preferences use the current user's thread-member settings.

## Automated evidence

Xcode 27.2, iOS 27.2 Simulator, mock/offline account operations only.

- Broad run: exit 0; 676 passed, one skipped, zero failures. Three independently reproduced baseline DuoLayoutTests failures were excluded: testHiddenSidebarRevealAndTitleSurviveScrolling, testHidingSidebarAfterScrollingKeepsReveal, testSidebarFooterSitsJustAboveHomeIndicator.
- Final affected run after the last settings-freshness adjustment: exit 0; 131 passed, zero failures. Covers ThreadNotificationTests, ThreadSidebarTests, SidebarThreadUnreadTests, OtherListCompletenessTests, NotificationSettingsTests and NotificationInheritanceTests.
- New list regressions verify archived membership supplied separately in `members`, flags/mute hydration, settings eligibility, and preservation of newer settings or leaving when archive/forum responses arrive late.
- Existing collapse, permissions, confirmed/refused writes, close/reopen archive placement and selected-thread deletion regressions pass.
- `git diff --check` passes.

Durable local logs, exit records and result bundles are retained in `/tmp/duocord-thread-evidence/`: r3-broad and r3-final-focused. Baseline comparison bundles are baseline-duolayout and mine-duolayout. Builds use the Xcode hygiene wrapper with private DerivedData; no shared caches were removed.

## Independent review

Three sol-loop rounds ran through T3 with Codex / GPT-6.1 Sol / high reasoning. The final review completed with APPROVE, verified the frozen code SHA-256, and found no actionable issues in the R3 target. All findings were resolved: correct thread-member notification transport and REST hydration, close/reopen archive placement, and the obsolete mute fixture. Usage was not exposed.

Final reviewed code diff SHA-256: `d85139468e7f411394c67f11da856df369604e018676b9e68aec04f78fb9f288` (tracked binary diff against 096f424 followed by sorted untracked Swift path, NUL and content). Local review reports remain at `/tmp/duocord-thread-review-r1.md`, `/tmp/duocord-thread-review-r2.md` and `/tmp/duocord-thread-review-r3.md`.

## Runtime proof remains blocked

No screenshots, recordings or app interactions were captured. The dedicated replacement Simulator builds and runs XCTest, but the device panel transport returned:

> No device 5E0E148C-FF1D-410C-991D-B0FD79D9B464 on 'This machine' (hostId local). Call device_list for current ids.

The prescribed device-list refresh and retry returned the same error. Device attempts stopped under the tool's retry boundary. Earlier REPORT.md and raw build records in this local directory describe an older source snapshot; they are not proof of the final behavior and are excluded from this PR.

Do not treat automated tests as visual verification. Before merge, run the app with `-DuocordMock YES` and verify disclosure/navigation independence, all thread-menu surfaces, rename/delete prompts, active/archive transitions, permissions and notification controls. `-DuocordMockThreadFail YES` exercises refusal feedback. No live Discord operations are needed.
