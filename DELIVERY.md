# TestFlight delivery

Alex's instruction, 2026-11-02: keep the TestFlight version up to date with our work. TestFlight is the delivery target for this project. Local builds and simulator checks support delivery; they are not the final handoff.

## Canonical app

- App Store Connect app: `6829036831`, existing Duocord.
- App bundle: `com.saphid.duocord`; Live Activity extension: `com.saphid.duocord.LiveActivity`.
- Launcher name: **Duocord Native**. Native source in this repository replaces the earlier web wrapper on the existing TestFlight channel.
- Reuse existing internal tester groups. Do not create public links, invite new testers, or submit to external review as part of routine updates.
- Keep the native session/login Keychain service names separate. The web-wrapper update may require a fresh sign-in; do not extract or migrate web credentials.

## Completion workflow

1. Finish the change, run relevant mock/offline checks and obtain a fresh independent source review when capacity is available.
2. Check the latest App Store Connect build and choose a strictly newer timestamp build number. Preserve the source manifest and verification receipts with the release.
3. Run `BUILD_NUMBER=<number> scripts/testflight.sh` to archive, verify app and extension identities/build numbers, and upload. `DESTINATION=export` prepares an IPA without upload when needed for diagnostics.
4. Run `BUILD=<number> NOTES_FILE=<release-notes-path> scripts/testflight-share.sh`. It waits up to ten minutes for processing, updates build notes, reuses existing internal groups, and verifies group assignment and internal testing state. Exit 75 means Apple processing or availability is still pending; inspect its receipt before retrying.
5. Read back the exact build number and TestFlight state. Report available only after Apple reports `VALID` and `IN_BETA_TESTING` for the assigned existing group. An upload or a local archive alone is not availability.
6. Record the release path, real command exits, source manifest, known verification limits and any Apple processing/rejection in `build/HANDOFF.md` and the owning issue when an update is authorized.
7. Publish the exact released source to the public repository `saphid/duocord-native`. Commit the frozen manifest inputs onto `main`, keeping this file and `README.md` at their current `main` versions. Name the build number and manifest SHA256 in the commit message, tag it `testflight/<build>` and push both. Run the secret scan (`trufflehog git file://<repo> --branch main`) before every push. A release isn't complete until public `main` matches the TestFlight source.

Routine TestFlight uploads and updates are authorized by Alex's instruction. This does not lift stopped manual-device driving, authorize live Discord operations, or require App Store production release. Do not use direct phone development installs as the normal delivery path. Keep account actions mock/offline during checks, and state unresolved keyboard/fold/runtime limits accurately in the build notes.

This is the workflow for each completed work batch; it is not a separately scheduled background automation.
