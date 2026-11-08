Server dragging and Leave Server

Drag a server before another server to save its order. Server menus also offer Move to Top/Bottom and Leave Server with a named confirmation, Cancel, owner protection and refusal feedback. Confirmed departure removes only that server’s conversations and local unsent work.

Native proof on the dedicated iOS 27.2 simulator passed primary drag, Cancel, confirmed leave/DM return, drag after leaving, and injected 403 reorder failure retention. The original native failure was an undeclared custom drag type; adding its exported bundle declaration restored target recognition. [Observed results and Before/After media](RESULT.md), [machine receipt](ui-verification.json).

After the native fix, 27 focused tests passed: 15 feature methods and 12 route-contract methods, including the exported-type bundle regression. The earlier filtered suite passed 851 methods with 2 skipped and zero failures; seven reproduced release-baseline failures were excluded. [Verification](verification.json).

Reviewed with sol-loop: 3 rounds of fresh GPT-6.1 Sol high instances; the full feature was approved in round 2 and the four-file native fix in round 3, with no actionable findings. Same-model review limitation applies; Opus was unavailable at rate limit. [Review receipts](review-ledger.json).

The PR is based on shipped TestFlight source 2da02168 on app-store/approval-20261108 to preserve App Store readiness. All UI actions used fictional MockDiscord data. Live Discord writes, backend durability, cross-launch persistence and all-long-hold reliability were not verified. Fresh mock launches reset the fixture. Raw command logs and uncut recordings remain in the local build evidence directory; published GIFs use 12 fps sampling at original elapsed timing.
