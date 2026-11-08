import SwiftUI

@main
struct DuocordNativeApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Perf.shared.markOnce("appInit")
        NotificationService.shared.activate()
        // Start before the first frame so it already shows the last session.
        // (No web views are created here: they must wait for the window.)
        let model = AppModel()
        NotificationService.shared.onOpen = { [model] channel, message in model.open(channel: channel, message: message) }
        model.connectAlertActions(NotificationService.shared)
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.store)
                .environment(model.settings)
                .environment(model.fold)
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(FoldState.self) private var fold

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading:
                Color.chatBackground.ignoresSafeArea()
            case .riskNotice:
                RiskNoticeView()
            case .signedOut:
                WelcomeView()
            case .signedIn:
                MainView()
            }
        }
        .background { FoldReader(state: fold).ignoresSafeArea() }
        .background { WindowThemer(revision: ThemeStore.shared.revision) }
        .tint(.accentBlurple)
    }
}

/// First run: the account risk, stated plainly before anything else.
struct RiskNoticeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Before you sign in")
                    .font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Text("Duocord is an unofficial Discord client. It signs in with your own account through Discord's login page and then talks to Discord the way Discord's web app does.")
                    Text("Discord's Terms of Service don't allow third-party clients that use your account's token. Discord can limit, suspend or close accounts that use them.")
                        .fontWeight(.semibold)
                    Text("Duocord sends your actions to Discord. Read receipts and typing indicators can be sent automatically while you use it; you can turn them off in Settings. Your token is stored in this device's Keychain and sent only to Discord.")
                }
                .font(.body)
                .foregroundStyle(Color.textSecondary)
                Button {
                    model.acknowledgeRisk()
                } label: {
                    Text("I Understand the Risk")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("acknowledgeRisk")
                Button("Explore Demo") { model.startDemo() }
                    .accessibilityIdentifier("exploreDemo")
                Text("Explore fictional conversations without signing in. Demo changes are not sent to Discord.")
                    .font(.footnote)
                Link("Privacy Policy", destination: URL(string: "https://saphid.app/duocord-native/privacy")!)
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.chatBackground.ignoresSafeArea())
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showLogin = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentBlurple)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Duocord").font(.largeTitle.bold())
                Text("Discord, made for iPhone Duo.")
                    .font(.title3)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Button {
                showLogin = true
            } label: {
                Text("Sign In with Discord")
                    .frame(maxWidth: 420, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .accessibilityIdentifier("signIn")
            Button("Explore Demo") { model.startDemo() }
                .accessibilityIdentifier("exploreDemo")
            Link("Privacy Policy", destination: URL(string: "https://saphid.app/duocord-native/privacy")!)
            Text("You'll sign in on Discord's own page, so captcha and two-factor work as usual.")
                .font(.footnote)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chatBackground.ignoresSafeArea())
        .onAppear {
            // An owner-provisioned install opens Discord's login straight away.
            #if DEBUG
            if UserDefaults.standard.bool(forKey: LoginStore.autoSignInKey) { showLogin = true }
            #endif
        }
        .sheet(isPresented: $showLogin) {
            LoginSheet { credentials in
                showLogin = false
                model.signIn(with: credentials)
            }
        }
    }
}
