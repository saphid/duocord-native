# Duocord Native

A native SwiftUI Discord client for iOS 27, built first for the iPhone Duo foldable and also for iPad.

`main` tracks the exact source of the latest TestFlight build. Each release commit names its build number and source-manifest hash, and is tagged `testflight/<build>`.

- [PLAN.md](PLAN.md): architecture and design principles
- [DELIVERY.md](DELIVERY.md): build, verification and TestFlight release workflow
- [docs/VOICE.md](docs/VOICE.md): voice notes

## Building

Requires Xcode 27.2 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open DuocordNative.xcodeproj
```

The test suite runs offline against mocks (`Discord/Mock.swift`). Signing settings in `project.yml` belong to the maintainer, so set your own team to run on a device.

## Status

Personal project. It isn't affiliated with or endorsed by Discord. Use of unofficial clients may be against Discord's Terms of Service; you use it at your own risk.
