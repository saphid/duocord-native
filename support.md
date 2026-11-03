# Duocord support

Duocord is an unofficial, third-party client for Discord, for iPhone and iPad (iOS and iPadOS 27.1 or later), designed first for iPhone Duo. It isn't affiliated with, endorsed by or sponsored by Discord Inc.

## Get help

- **Report a problem or ask a question:** [open an issue](https://github.com/saphid/duocord-native/issues). Say which device you use, your iOS version and the Duocord version (shown on the App Store and in TestFlight).

Please don't post your Discord token, password, private messages or screenshots of other people's messages in public issues.

## Before you sign in

Duocord signs in to your own Discord account on Discord's own login page. Discord's Terms of Service don't allow third-party clients that use your account's token, and Discord can limit, suspend or close accounts that use them. Use Duocord only if you accept that risk. Duocord sends your messages and actions to Discord and, if you allow it in Settings, read state and typing indicators.

## Common questions

**How do I sign in?** Tap **I Understand the Risk**, then **Sign In with Discord**, and finish Discord's login (captcha and two-factor work as usual).

**How do I sign out?** Settings → **Sign Out**. Your session token is removed from the device's Keychain.

**Why don't notifications arrive when the app is closed?** Duocord has no push server. Alerts come only while it's connected to Discord, in the foreground or in the background with **Stay Connected in Background** on. Stay Connected in Background plays silent audio to keep the connection open, which uses more battery; it is not remote push. Alerts don't arrive after you force-quit the app.

**What does voice support?** Audio in server voice channels: join, mute, deafen and leave, with a Live Activity on the Lock Screen and in the Dynamic Island. DM calls, video and screen sharing aren't supported.

**iPhone Duo:** when it's half-open like a book, servers and channels fill the left page and the chat fills the right. You can turn this off in Settings → iPhone Duo. In table-top pose, messages sit above the fold and controls below.

## Privacy

See the [privacy policy](privacy.md). The developer collects no data.

## Source code

[github.com/saphid/duocord-native](https://github.com/saphid/duocord-native)
