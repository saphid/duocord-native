# Duocord privacy policy

Last updated: 3 November 2026

Duocord is an unofficial, third-party client for Discord, made by an independent developer. It isn't affiliated with, endorsed by or sponsored by Discord Inc. This policy covers the Duocord app for iPhone and iPad (bundle `com.saphid.duocord`).

## Summary

The developer of Duocord does not collect, receive, store, sell or share any of your data. Duocord has no developer-run servers, no accounts of its own, no analytics, no advertising and no third-party SDKs. Your Discord data goes directly between your device and Discord.

## What Duocord sends, and where

Duocord connects only to services that Discord operates or references:

- **Discord's login page** (`discord.com/login`), shown inside the app. You sign in on Discord's own page. Its captcha, passkey, two-factor and "Sign in with Apple/Google" steps may load pages from hcaptcha.com, recaptcha.net, google.com, gstatic.com or apple.com.
- **Discord's API and gateway** (`discord.com/api`, `gateway.discord.gg`). Duocord loads your servers, channels, messages, friends and settings from them, and sends the messages, attachments, reactions, edits, deletes, pins, read state, typing indicators, friend actions and notification settings you choose to send.
- **Attachment uploads** go to the upload address Discord provides for each file.
- **Images and media** load from Discord's CDN and media proxy (`cdn.discordapp.com`, `media.discordapp.net`). Some embedded media, such as animated GIF videos in link embeds, may load directly from the website named in Discord's embed data.
- **Voice calls.** When you join a voice channel, Duocord runs Discord's own web client in a hidden, temporary web view on `discord.com`, which carries the call and its microphone audio. The web view stores nothing between calls and is removed when you leave.

While you use Discord through Duocord, Discord processes your data under [Discord's Privacy Policy](https://discord.com/privacy). The Duocord developer operates no app-data backend. Discord and the providers used by its embedded login and voice pages process data under their own privacy policies, and Discord may keep account data and diagnostics after a request or call ends. Signing out of Duocord does not delete data held by Discord; use Discord's privacy tools to request access or deletion. Discord's own login page and web client, shown inside Duocord, may send Discord their own diagnostics. Duocord doesn't control them.

Links that aren't Discord message links open in your default browser.

## What stays on your device

- **Your Discord session token**, saved in the iOS Keychain with "this device only" protection. It is sent only to Discord. Signing out deletes it.
- **Caches** in the app's Caches folder, so the app opens quickly: your last session (server list and recent messages, with iOS file protection) and downloaded images. Signing out deletes the session cache. iOS may clear caches at any time.
- **Preferences** (theme, notification toggles, recent emoji) in the app's settings storage.
- **A local performance log** (timings, counts and channel IDs, no message text), written to the app's Documents folder. Duocord never sends it anywhere.

Developer-provisioned test installs may also store a Discord login email address and password in this device's Keychain to pre-fill Discord's login page. The provisioning file is deleted after import. Sign Out removes the session token and session cache, but not this saved login, downloaded-media caches or the local performance log.

Deleting the app removes these files. iOS can keep Keychain items after an app is deleted, so sign out first to remove the token.

## Permissions

- **Microphone:** used only during voice calls you join.
- **Photos:** the system photo picker gives Duocord only the photos you choose to attach. Duocord 1.0 doesn't read your photo library or save to it.
- **Notifications:** local alerts for new messages while Duocord is connected. Duocord doesn't use remote push servers.
- **Camera:** Duocord 1.0 does not use the camera.

## Children

Duocord is not directed at children. Discord sets its own minimum age for accounts.

## Your choices

You can sign out at any time in Settings. To access, correct or delete the data in your Discord account, use Discord's own tools and [Discord's Privacy Policy](https://discord.com/privacy). The Duocord developer holds no copy of it.

## Changes and contact

Changes to this policy are published in this file's history in the public repository.

Questions: [open an issue](https://github.com/saphid/duocord-native/issues).
