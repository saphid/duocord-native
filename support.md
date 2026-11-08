# Duocord support

Updated 9 November 2026. This page describes Duocord App Store candidate **1.0 (202611082011)**, which is not yet publicly released. Earlier developer/TestFlight builds may differ as noted below.

Duocord is an unofficial, third-party client for Discord, for iPhone and iPad (iOS and iPadOS 27.1 or later), designed first for iPhone Duo. It isn't affiliated with, endorsed by or sponsored by Discord Inc.

## Get help

- **Private support and content reports:** email [saphid@gmail.com](mailto:saphid@gmail.com), the developer’s private support contact. Reports are addressed to Alex Southwell, Duocord’s developer.
- **Public bug reports:** [open an issue](https://github.com/saphid/duocord-native/issues) only when the report contains no private or sensitive content. Include your device, iOS version and Duocord version.

Please don't post your Discord token, password, private messages or screenshots of other people's messages in public issues.

## Report content privately

In App Store candidate 1.0 (202611082011), long-press a message and choose **Report Message**, or use **Settings → Report Content**. Select a reason and optionally describe the concern. The report includes the selected message link, reason and text you enter; the app does not automatically attach message text, media, credentials or logs. Review the draft and choose **Send** in your email app. If no email app is available, choose **Copy Report** and email it yourself. Opening a composer or copying text does not submit a report. Fictional demo mode disables email and clipboard reporting.

You can also [report directly to Discord](https://discord.com/safety/360044103651-reporting-abusive-behavior-to-discord) for enforcement on Discord, and block the sender from their profile in Duocord. The Duocord developer cannot remove messages from Discord’s servers. For an immediate threat to someone’s safety, contact your local emergency service.

Reports are addressed to the developer’s support inbox. Duocord does not provide a delivery receipt. Check your email app to confirm sending; opening or copying a report alone is insufficient.

## Before you sign in

Duocord signs in to your own Discord account on Discord's own login page. Discord's Terms of Service don't allow third-party clients that use your account's token, and Discord can limit, suspend or close accounts that use them. Use Duocord only if you accept that risk. Duocord sends your messages and actions to Discord. Read state and typing indicators can be sent automatically while you use the app; you can turn them off in Settings.

## Common questions

**Can I try it without signing in?** Tap **Explore Demo** on the first-run notice or welcome screen. The demo uses fictional local data and shows **Demo · Fictional data**. **Exit Demo** returns to the welcome flow and preserves any stored real-account session.

**How do I sign in?** Tap **I Understand the Risk**, then **Sign In with Discord**, and finish Discord's login (captcha and two-factor work as usual).

**How do I sign out?** Settings → **Sign Out**. Your session token is removed from the device's Keychain.

**Why don't notifications arrive when the app is closed?** Duocord has no push server. It follows each server's notification settings while connected, and background message delivery is not guaranteed. The App Store candidate does not play silent audio to keep a message connection open. Active voice calls can use background audio. Alerts do not arrive after you force-quit the app. Older developer test builds may have included a silent-audio setting; that setting is absent from this candidate.

**Why are some channels missing?** Channels marked age-restricted and their known children/threads are unavailable. Content also stays hidden when the app cannot verify channel ancestry. There is no in-app opt-in to age-restricted channels.

**What does voice support?** Audio in server voice channels: join, mute, deafen and leave, with a Live Activity on the Lock Screen and in the Dynamic Island. DM calls, video and screen sharing aren't supported.

**iPhone Duo:** when it's half-open like a book, servers and channels fill the left page and the chat fills the right. You can turn this off in Settings → iPhone Duo. In table-top pose, messages sit above the fold and controls below.

## Privacy

See the [privacy policy](privacy.md) for local storage and Discord's processing. Duocord has no developer-run app-data backend.

## Source code

[github.com/saphid/duocord-native](https://github.com/saphid/duocord-native)
