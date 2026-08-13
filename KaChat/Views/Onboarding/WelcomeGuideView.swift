import SwiftUI

/// First-run guided walkthrough shown automatically right after onboarding a wallet - whether it
/// was freshly created or imported (see `WalletManager.justCreatedNewWallet`) - and replayable any
/// time from the Profile section. Mirrors `KNSCreateProfileFlowView`'s step-enum-driven single-view
/// wizard shape rather than a `TabView`/`NavigationStack` push-per-step, since every step here is
/// simple static content plus at most one piece of live state (no per-step async work to gate on).
struct WelcomeGuideView: View {
    let onFinished: () -> Void

    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @EnvironmentObject private var giftService: GiftService

    private enum Step: Int, CaseIterable {
        case welcome
        /// "Who will use KaChat?" - Adult continues as normal, Child sets a password and turns
        /// Child Mode on from first launch. Deliberately placed BEFORE the language step.
        case userType
        case language
        case currency
        case fees
        case funding
        case nodeConnection
        case addressExplainer
        case chatting
    }

    private enum NodeChoice: Equatable {
        case defaultNode
        case ownNode
        case autoDiscover
    }

    private enum UserTypeChoice: Equatable {
        case adult
        case child
    }

    @State private var step: Step = .welcome
    @State private var userTypeChoice: UserTypeChoice = .adult
    @State private var childPasswordInput = ""
    @State private var childPasswordConfirm = ""
    @State private var childSetupError: String?
    @State private var nodeChoice: NodeChoice = .defaultNode
    @State private var ownNodeInput = ""
    @State private var nodeValidationError: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    private var chattingAddress: String {
        walletManager.currentWallet?.publicAddress ?? ""
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Skip") { onFinished() }
                    }
                }
        }
        .toast(message: toastMessage)
        .onAppear {
            nodeChoice = currentNodeChoiceFromSettings()
            ownNodeInput = settingsViewModel.settings.trustedNodeAddress == AppSettings.defaultTrustedNodeAddress
                ? "" : settingsViewModel.settings.trustedNodeAddress
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            scaffold(
                icon: "hand.wave.fill",
                title: "Welcome to KaChat",
                body: "Let's walk through the basics so you're ready to send your first message.",
                buttonTitle: "Next",
                extra: { EmptyView() }
            ) { step = .userType }

        case .userType:
            userTypeStep

        case .language:
            languageStep

        case .currency:
            currencyStep

        case .fees:
            scaffold(
                icon: "network",
                title: "How KaChat Uses Kaspa",
                body: "KaChat lets you send and receive messages on the Kaspa network itself. Kaspa is required to pay fees when sending your messages. The fee you pay goes to miners which secure the network.",
                buttonTitle: "Next",
                extra: { EmptyView() }
            ) { step = .funding }

        case .nodeConnection:
            nodeConnectionStep

        case .funding:
            fundingStep

        case .addressExplainer:
            addressExplainerStep

        case .chatting:
            scaffold(
                icon: "bubble.left.and.bubble.right.fill",
                title: "Starting a Conversation",
                body: "To chat with someone, press Create Chat and enter their Kaspa address or KNS domain. If you send a message, they will not see it unless you send a handshake first, or you both decide to message each other around the same time - doing the latter increases your privacy.",
                buttonTitle: "Finish",
                extra: { EmptyView() }
            ) { onFinished() }
        }
    }

    // MARK: - Shared step scaffold

    @ViewBuilder
    private func scaffold(
        icon: String,
        title: String,
        body: String,
        buttonTitle: String,
        @ViewBuilder extra: () -> some View,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text(LocalizedStringKey(title))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(LocalizedStringKey(body))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            extra()
            Spacer()
            Button(action: action) {
                Text(LocalizedStringKey(buttonTitle))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Who-will-use step (Child Mode)

    /// Adult continues untouched; Child sets a free-form password (stored salted-hashed in the
    /// Keychain, see ChildModeService) and Child Mode turns ON immediately - persisted via
    /// saveSettings() right here at the step, not deferred to the end of the guide, so the
    /// choice survives no matter what the rest of the wizard writes (or whether it finishes).
    /// When the guide is REPLAYED (Profile > Help) with Child Mode already on, the step is
    /// informational only - offering "Adult" there would be a password-free way out.
    private var userTypeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "figure.and.child.holdinghands")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Who will use KaChat?")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if settingsViewModel.settings.childModeEnabled {
                Text("Child Mode is on. Chats, Group Chats, Portfolio and Cold Storage are available; Swaps, KaPosts and Broadcasts are hidden. Manage this in Settings > Security > Child Mode.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                Text("A child gets a simpler, safer KaChat: just Chats, Group Chats, Portfolio and Cold Storage. Swaps, KaPosts and Broadcasts stay hidden until an adult unlocks them.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                ScrollView {
                    VStack(spacing: 10) {
                        userTypeRow(
                            choice: .adult,
                            icon: "person.fill",
                            title: "Adult",
                            subtitle: "The full app, everything available."
                        )
                        userTypeRow(
                            choice: .child,
                            icon: "figure.child",
                            title: "Child",
                            subtitle: "Chats, Portfolio and Cold Storage only. An adult sets a password to unlock the rest later."
                        )

                        if userTypeChoice == .child {
                            VStack(alignment: .leading, spacing: 8) {
                                SecureField("Password", text: $childPasswordInput)
                                    .textContentType(.oneTimeCode)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                    .padding(10)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                SecureField("Confirm password", text: $childPasswordConfirm)
                                    .textContentType(.oneTimeCode)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                    .padding(10)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text("4 digits, 8 digits, or anything you like - just don't forget it. It's needed to turn Child Mode off.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 4)
                            .onChange(of: childPasswordInput) { _ in childSetupError = nil }
                            .onChange(of: childPasswordConfirm) { _ in childSetupError = nil }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                }

                if let childSetupError {
                    Text(childSetupError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }

            Spacer()
            Button {
                applyUserTypeChoice()
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func userTypeRow(choice: UserTypeChoice, icon: String, title: String, subtitle: String) -> some View {
        Button {
            userTypeChoice = choice
            childSetupError = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: userTypeChoice == choice ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(userTypeChoice == choice ? .accentColor : .secondary)
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func applyUserTypeChoice() {
        // Replay with Child Mode already on: purely informational, just continue.
        if settingsViewModel.settings.childModeEnabled {
            step = .language
            return
        }
        switch userTypeChoice {
        case .adult:
            step = .language
        case .child:
            let password = childPasswordInput
            guard !password.isEmpty else {
                childSetupError = "Enter a password first."
                return
            }
            guard password == childPasswordConfirm else {
                childSetupError = "Passwords don't match."
                return
            }
            do {
                try ChildModeService.shared.setPassword(password)
            } catch {
                childSetupError = "Couldn't save the password. Please try again."
                return
            }
            settingsViewModel.settings.childModeEnabled = true
            settingsViewModel.saveSettings()
            childPasswordInput = ""
            childPasswordConfirm = ""
            childSetupError = nil
            Haptics.success()
            step = .language
        }
    }

    // MARK: - Language step

    /// Picking a language here applies immediately, live, like the currency step below it - the
    /// whole app re-renders in the new language right away via `.environment(\.locale, ...)` in
    /// `KaChatApp.swift`, so the rest of this guide continues normally in the newly-picked
    /// language with no restart and no need to re-launch the guide from the top.
    private var languageStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Choose Your Language")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Select the language you'd like to use in KaChat.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        languageRow(language)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }

            Button {
                step = .currency
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        let isSelected = settingsViewModel.settings.language == language
        return Button {
            guard !isSelected else { return }
            settingsViewModel.settings.language = language
            settingsViewModel.saveSettings()
            settingsViewModel.applyLanguagePreference(language)
        } label: {
            HStack {
                Text(language.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Currency step

    /// Only affects Portfolio's live KAS price/value display (see `CoinGeckoService`,
    /// `PortfolioViewModel`) - unlike language, this takes effect immediately with no restart, so
    /// there's no restart alert here and the guide simply continues to Fees on tap.
    private var currencyStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Choose Your Currency")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Select the currency you'd like prices displayed in.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AppCurrency.allCases, id: \.self) { currency in
                        currencyRow(currency)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }

            Button {
                step = .fees
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func currencyRow(_ currency: AppCurrency) -> some View {
        let isSelected = settingsViewModel.settings.currency == currency
        return Button {
            guard !isSelected else { return }
            settingsViewModel.settings.currency = currency
            settingsViewModel.saveSettings()
        } label: {
            HStack {
                Text(currency.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Funding step

    private var fundingStep: some View {
        scaffold(
            icon: "qrcode",
            title: "Fund Your Chatting Address",
            body: "Let's fund your chatting address so that you can start chatting with people. 5-10 Kaspa is enough. (1 KAS is about ~500 messages)",
            buttonTitle: "Next",
            extra: {
                VStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = chattingAddress
                        Haptics.success()
                        showToast("Address copied to clipboard.")
                    } label: {
                        Text(chattingAddress)
                            .font(.footnote.monospaced())
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 24)
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        ChattingAddressQRView(
                            address: chattingAddress,
                            balanceSompi: walletManager.currentWallet?.balanceSompi
                        )
                    } label: {
                        Label("Show QR Code", systemImage: "qrcode")
                            .font(.subheadline.weight(.semibold))
                    }

                    giftClaimSection
                }
            },
            action: { step = .nodeConnection }
        )
    }

    /// Same `GiftService.shared` state machine already surfaced in Settings/Profile
    /// (`ContactsView.swift`'s `giftSection`) - offered here too since a brand-new account with a
    /// zero balance is exactly the moment this is most useful, right where the guide is already
    /// asking the user to fund their chatting address. Unlike the Profile card's version, this one
    /// stays visible in every state rather than disappearing once claimed/unavailable - it just
    /// grays out and relabels itself, so the guide never has a step that silently loses a whole
    /// row of content depending on gift state.
    private var giftClaimSection: some View {
        VStack(spacing: 6) {
            Button {
                guard giftService.claimState == .eligible,
                      let address = walletManager.currentWallet?.publicAddress else { return }
                Task { await giftService.claimGift(walletAddress: address) }
            } label: {
                HStack(spacing: 8) {
                    if giftService.claimState == .claiming {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: giftButtonIcon)
                    }
                    Text(giftButtonTitle)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isGiftClaimable ? Color.accentColor : Color(.systemGray4))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!isGiftClaimable)

            if case .unavailable(let reason) = giftService.claimState {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 4)
    }

    private var isGiftClaimable: Bool {
        giftService.claimState == .eligible
    }

    private var giftButtonIcon: String {
        switch giftService.claimState {
        case .claimed:
            return "checkmark.circle.fill"
        default:
            return "gift.fill"
        }
    }

    private var giftButtonTitle: String {
        switch giftService.claimState {
        case .checking, .eligible:
            return "Claim a Gift of 3 Kaspa to Get Started"
        case .claiming:
            return "Claiming gift..."
        case .claimed:
            return "Gift claimed"
        case .alreadyClaimed:
            return "Gift already claimed"
        case .unavailable:
            return "Gift unavailable"
        }
    }

    // MARK: - Node connection step

    private var nodeConnectionStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Connect to a Node")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("KaChat needs to connect to a node. How would you like to connect?")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                nodeChoiceRow(
                    choice: .defaultNode,
                    title: "Default",
                    badge: "Recommended",
                    subtitle: AppSettings.defaultTrustedNodeAddress
                )
                nodeChoiceRow(
                    choice: .ownNode,
                    title: "Connect Your Own Node",
                    badge: "Best",
                    subtitle: "Enter a node address you trust"
                )
                if nodeChoice == .ownNode {
                    TextField("host:port or grpcs://host", text: $ownNodeInput)
                        .font(.system(.footnote, design: .monospaced))
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 24)
                        .onChange(of: ownNodeInput) { _ in nodeValidationError = nil }
                }
                nodeChoiceRow(
                    choice: .autoDiscover,
                    title: "Auto Search for Nodes",
                    badge: nil,
                    subtitle: "Most taxing on the device, not as reliable - depends on where you live"
                )
            }
            .padding(.horizontal, 24)

            if let nodeValidationError {
                Text(nodeValidationError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
            }

            Spacer()
            Button {
                applyNodeChoice()
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func nodeChoiceRow(choice: NodeChoice, title: String, badge: String?, subtitle: String) -> some View {
        Button {
            nodeChoice = choice
            nodeValidationError = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: nodeChoice == choice ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(nodeChoice == choice ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        if let badge {
                            Text(LocalizedStringKey(badge))
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func currentNodeChoiceFromSettings() -> NodeChoice {
        let current = settingsViewModel.settings.trustedNodeAddress
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .autoDiscover
        }
        if current == AppSettings.defaultTrustedNodeAddress {
            return .defaultNode
        }
        return .ownNode
    }

    private func applyNodeChoice() {
        let valueToApply: String
        switch nodeChoice {
        case .defaultNode:
            valueToApply = AppSettings.defaultTrustedNodeAddress
        case .autoDiscover:
            valueToApply = ""
        case .ownNode:
            valueToApply = ownNodeInput
        }

        if let error = settingsViewModel.applyTrustedNode(valueToApply) {
            nodeValidationError = error
            return
        }
        nodeValidationError = nil
        step = .addressExplainer
    }

    // MARK: - Address explainer step

    private var addressExplainerStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Chatting vs. Spending Address")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Image("AddressTypesExplainer")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 12) {
                addressMockRow(
                    icon: "bubble.left.and.bubble.right.fill",
                    title: "Chatting Address",
                    address: chattingAddress,
                    caption: "Your public messaging identity. Fund it with a small amount to pay message fees and KNS profile creation fees - never send money here that you intend to spend."
                )
                addressMockRow(
                    icon: "dollarsign.circle.fill",
                    title: "Spending Address",
                    address: walletManager.currentSpendingAddress() ?? "",
                    caption: "Where you send and receive Kaspa you intend to use as money."
                )
            }
            .padding(.horizontal, 24)

            Spacer()
            Button {
                step = .chatting
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func addressMockRow(icon: String, title: String, address: String, caption: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                if !address.isEmpty {
                    Text(address)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(LocalizedStringKey(caption))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}
