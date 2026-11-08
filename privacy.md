# Duocord privacy policy

Updated 9 November 2026. This page describes Duocord App Store candidate **1.0 (202611082011)**, which is not yet publicly released. Earlier developer/TestFlight builds may differ as noted below.

Duocord is an unofficial, third-party client for Discord, made by an independent developer. It isn't affiliated with, endorsed by or sponsored by Discord Inc. This policy covers the Duocord app for iPhone and iPad (bundle `com.saphid.duocord`).

## Summary

Duocord has no developer-run app-data server, separate account system, developer analytics SDK or advertising SDK. Account requests and the content you send go from your device to Discord or the upload address Discord supplies. Discord and services used by its embedded web pages process data under their own policies; this includes processing beyond real-time request delivery.

## What Duocord sends, and where

For account and content features, Duocord connects to services that Discord operates or references:

- **Discord's login page** (`discord.com/login`), shown inside the app. You sign in on Discord's own page. Its captcha, passkey, two-factor and "Sign in with Apple/Google" steps may load pages from hcaptcha.com, recaptcha.net, google.com, gstatic.com or apple.com.
- **Discord's API and gateway** (`discord.com/api`, `gateway.discord.gg`). Duocord loads your servers, channels, messages, friends and settings from them, and sends the messages, attachments (including audio files), reactions, edits, deletes, pins, search queries, friend actions and notification settings. While you use the app, read state and typing indicators can be sent automatically; you can turn them off in Settings.
- **Attachment uploads** go to the upload address Discord provides for each file.
- **Images and media** load from Discord's CDN and media proxy (`cdn.discordapp.com`, `media.discordapp.net`). Some embedded media, such as animated GIF videos in link embeds, may load directly from the website named in Discord's embed data.
- **Voice calls.** When you join a voice channel, Duocord runs Discord's own web client in a hidden, temporary web view on `discord.com`, which carries the call and its microphone audio. The web view uses a non-persistent website data store and is removed when you leave. This local storage choice does not prevent Discord from retaining server-side information.

While you use Discord through Duocord, Discord processes your data under [Discord's Privacy Policy](https://discord.com/privacy). The Duocord developer operates no app-data backend. Discord and the providers used by its embedded login and voice pages process data under their own privacy policies, and Discord may keep account data and diagnostics after a request or call ends. Signing out of Duocord does not delete data held by Discord; use Discord's privacy tools to request access or deletion. Discord's own login page and web client, shown inside Duocord, may send Discord diagnostics. Discord's policy describes using information for service delivery, safety, product improvement, personalization and sponsored content, subject to its settings and policies. Duocord's developer does not control Discord's retention or these web-page practices. Uploaded recordings are files retained by Discord; they are different from live call audio.

Links that aren't Discord message links open in your default browser.

## Support and content reports

If you choose to email a report, your email provider delivers it to the developer at `saphid@gmail.com`. The developer receives your sender address, email contents and any attachments you choose to add. The app prepares only the selected message link, report reason and text you enter. It does not automatically attach message text, files, account credentials or logs. Your email app requires you to choose Send; merely opening or copying a report does not submit it. The fictional demo disables reporting email and clipboard actions.

Support correspondence is separate from the app’s Discord connection and is held in the developer’s email account to investigate and respond to your request. Do not send tokens, passwords or unnecessary private content. Contact the same address for deletion of support correspondence. Support correspondence is stored in the developer’s mailbox; Duocord does not automatically delete that email when you sign out or delete the app.

## What stays on your device

- **Your Discord session token**, saved in the iOS Keychain with "this device only" protection. It is sent only to Discord. Signing out deletes it.
- **Caches** in the app's Caches folder, so the app opens quickly: your last session (server list and recent messages, with iOS file protection) and downloaded images. Signing out deletes the session cache. iOS may clear caches at any time.
- **Preferences** (theme, notification toggles, recent emoji) in the app's settings storage.
- **A local performance log** (timings, counts and channel IDs, no message text), written to the app's Documents folder. Duocord never sends it anywhere.

The App Store candidate does not import provisioned login email/password files or pre-fill saved login details. Older developer test builds may have stored login details in the device Keychain. Updating to this version does not delete those legacy entries. Sign Out removes the session token and session cache, but not legacy saved login details, downloaded-media caches or the local performance log. Exiting the fictional demo preserves any stored real-account session and navigation preferences.

Deleting the app removes these files. iOS can keep Keychain items after an app is deleted, so sign out first to remove the token.

## Permissions

- **Microphone:** used only during voice calls you join.
- **Photos:** the system photo picker gives Duocord only the photos you choose to attach. Duocord 1.0 doesn't read your photo library or save to it.
- **Notifications:** local alerts for new messages while Duocord is connected. Duocord doesn't use remote push servers.
- **Camera:** Duocord 1.0 does not use the camera.

## Children

Duocord is not directed at children. Discord sets its own minimum age for accounts. This version hides channels labelled age-restricted, including their known child channels and threads, and keeps content unavailable if its ancestry cannot be checked. This does not establish that all user-generated content is suitable or moderated.

## Your choices

You can sign out at any time in Settings. To access, correct or delete the data in your Discord account, use Discord's own tools and [Discord's Privacy Policy](https://discord.com/privacy). The Duocord developer holds no copy of your Discord account data except information you voluntarily include in support correspondence.

## Changes and contact

Changes to this policy are published in this file's history in the public repository.

Private questions and content reports: [saphid@gmail.com](mailto:saphid@gmail.com), addressed to Alex Southwell, the developer. Use public GitHub issues only for reports containing no private or sensitive information.
