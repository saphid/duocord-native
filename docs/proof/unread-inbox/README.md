# Unread inbox organization proof

Captured on an iPhone 17 Pro Simulator running iOS 27.2 with offline MockDiscord. Images are direct simulator captures, without editing.

- Grouped default: Server grouping, All filter, Recent Activity sort, section counts.
- Menu: native Group By, Show, and Sort By controls.
- No match: an unmatched search with recovery to all eligible unreads.

Observed UI checks covered grouping, all filter choices, all sort choices, search recovery, saved choices after relaunch, row navigation, and the existing global Mark All Read scope. Portrait and landscape sheets were inspected. Sidebar, fold transitions, VoiceOver, and a positive unread-thread fixture were not visually exercised. Automated tests cover thread inclusion and eligibility.

Focused simulator tests: 89 passed, 0 failed, 0 skipped, xcodebuild exit 0. Includes 13 new organization tests plus unread preview, sidebar thread unread, and list completeness coverage.

Independent source review: GPT-6.1 Sol, high reasoning, Codex Direct; completed with APPROVE and no actionable findings against base 4104c4ad3e1845d81776d4079019293e0ac0c4e5. One sol-loop round. Review task: node:delegated-task:command%3Amcp%3Ae1dd3939-9eb8-491a-ae4b-67755a4ce884%3Adelegate-task%3A39e631a2-a44d-4c4c-9b5c-805f0c8d9f17. Usage was not exposed.
