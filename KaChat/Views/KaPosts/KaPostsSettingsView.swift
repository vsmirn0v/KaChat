import SwiftUI

/// KaPosts' own settings, reached from the gear in the feed's icon row: which KaPosts
/// activity notifies you (moved here from Settings > Notifications), and the default tip -
/// the amount a tap on "Tip" sends at once, with no amount screen in between.
struct KaPostsSettingsView: View {
    let onClose: () -> Void

    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @State private var defaultTipText = ""
    @State private var instantTipEnabled = false

    private static let fallbackTipKas = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Send a default tip instantly", isOn: $instantTipEnabled)
                        .onChange(of: instantTipEnabled) { enabled in
                            if enabled {
                                if defaultTipText.trimmingCharacters(in: .whitespaces).isEmpty {
                                    defaultTipText = Self.trimmed(Self.fallbackTipKas)
                                }
                                commitDefaultTip()
                            } else {
                                settingsViewModel.settings.kaPostsDefaultTipSompi = nil
                                settingsViewModel.saveSettings()
                            }
                        }
                    if instantTipEnabled {
                        HStack {
                            Image("KaspaLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)
                            TextField("1", text: $defaultTipText)
                                .keyboardType(.decimalPad)
                                .numericKeyboardDoneButton()
                                .onSubmit { commitDefaultTip() }
                                .onChange(of: defaultTipText) { _ in commitDefaultTip() }
                            Text("KAS")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Tipping")
                } footer: {
                    Text(instantTipEnabled
                         ? "Tapping Tip on a post sends this amount straight away - no amount screen. It goes out exactly like a payment in that person's chat: from your primary spending address when Chats Payment Privacy is on, to a fresh private address of theirs when they shared one."
                         : "Off: tapping Tip opens the amount screen every time.")
                }

                Section {
                    NavigationLink {
                        KaPostsNotificationSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                } footer: {
                    Text("Choose which KaPosts activity reaches you: likes, dislikes, reposts, comments, follows and mentions.")
                }
            }
            .navigationTitle("KaPosts Settings")
            .navigationBarTitleDisplayMode(.inline)
            .kaPostsStatusChrome()
            .kaPostsSwipeBack { onClose() }
            .onAppear {
                if let sompi = settingsViewModel.settings.kaPostsDefaultTipSompi, sompi > 0 {
                    instantTipEnabled = true
                    defaultTipText = Self.trimmed(Double(sompi) / 100_000_000.0)
                }
            }
        }
    }

    private func commitDefaultTip() {
        guard instantTipEnabled else { return }
        let normalized = defaultTipText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let kas = Double(normalized), kas > 0 else { return }
        let sompi = UInt64((kas * 100_000_000).rounded())
        guard sompi != settingsViewModel.settings.kaPostsDefaultTipSompi else { return }
        settingsViewModel.settings.kaPostsDefaultTipSompi = sompi
        settingsViewModel.saveSettings()
    }

    private static func trimmed(_ kas: Double) -> String {
        var text = String(format: "%.8f", kas)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
