import SwiftUI

/// Settings > Security > Child Mode.
///
/// - No password yet: set one (enter + confirm) and Child Mode turns on in the same stroke.
/// - Password set: the ON/OFF toggle lives here. Turning OFF demands the password (wrong
///   password = stays on); turning back ON needs nothing. Plus a traditional change-password
///   flow (current -> new -> confirm; wrong current = error, nothing changes).
///
/// Deliberately NO biometrics anywhere in this flow - the device owner (the child) can pass
/// Face ID, so only manual password entry counts. See `ChildModeService` for the storage
/// design (salted SHA-256 in the Keychain, never plaintext).
struct ChildModeSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    /// Mirrors `ChildModeService.hasPassword`; kept in @State so the screen re-renders the
    /// moment the first password is set.
    @State private var hasPassword = false

    // First-time setup
    @State private var setupPassword = ""
    @State private var setupConfirm = ""
    @State private var setupError: String?

    // Turn-off prompt
    @State private var showTurnOffPrompt = false
    @State private var turnOffPassword = ""
    @State private var turnOffError: String?

    // Change password
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var newPasswordConfirm = ""
    @State private var changeError: String?
    @State private var changeSucceeded = false

    // Clear password (full reset)
    @State private var showClearPrompt = false
    @State private var clearPassword = ""
    @State private var clearError: String?

    var body: some View {
        Form {
            if hasPassword {
                toggleSection
                changePasswordSection
                clearPasswordSection
            } else {
                setupSection
            }
            aboutSection
        }
        .navigationTitle("Child Mode")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasPassword = ChildModeService.shared.hasPassword
        }
        .sheet(isPresented: $showTurnOffPrompt) {
            turnOffSheet
                .presentationDetents([.height(280)])
        }
        .sheet(isPresented: $showClearPrompt) {
            clearSheet
                .presentationDetents([.height(280)])
        }
    }

    private var isEnabled: Bool {
        settingsViewModel.settings.childModeEnabled
    }

    // MARK: - Toggle (password already set)

    private var toggleSection: some View {
        Section {
            Toggle("Child Mode", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    if newValue {
                        // Turning ON with a password already set needs no password.
                        settingsViewModel.settings.childModeEnabled = true
                        settingsViewModel.saveSettings()
                        Haptics.success()
                    } else {
                        // Turning OFF requires the password - don't change anything yet.
                        turnOffPassword = ""
                        turnOffError = nil
                        showTurnOffPrompt = true
                    }
                }
            ))
            .tint(.accentColor)
        } footer: {
            Text(isEnabled
                 ? "Child Mode is on. Turning it off requires the password."
                 : "A password is already set - turning Child Mode on doesn't ask for it.")
        }
    }

    /// Manual password entry sheet for switching Child Mode off. Wrong password = error, the
    /// toggle stays on. Never biometrics.
    private var turnOffSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $turnOffPassword)
                        .textContentType(.oneTimeCode)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: turnOffPassword) { _ in turnOffError = nil }
                } header: {
                    Text("Turn Off Child Mode")
                } footer: {
                    if let turnOffError {
                        Text(turnOffError)
                            .foregroundColor(.red)
                    } else {
                        Text("Enter the Child Mode password to turn it off.")
                    }
                }

                Section {
                    Button {
                        attemptTurnOff()
                    } label: {
                        Text("Turn Off")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .disabled(turnOffPassword.isEmpty)
                }
            }
            .navigationTitle("Child Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        showTurnOffPrompt = false
                    }
                }
            }
        }
    }

    private func attemptTurnOff() {
        guard ChildModeService.shared.verifyPassword(turnOffPassword) else {
            turnOffError = "Wrong password. Child Mode stays on."
            Haptics.error()
            turnOffPassword = ""
            return
        }
        settingsViewModel.settings.childModeEnabled = false
        settingsViewModel.saveSettings()
        turnOffPassword = ""
        showTurnOffPrompt = false
        Haptics.success()
    }

    // MARK: - First-time setup (no password yet)

    private var setupSection: some View {
        Section {
            SecureField("Password", text: $setupPassword)
                .textContentType(.oneTimeCode)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: setupPassword) { _ in setupError = nil }
            SecureField("Confirm password", text: $setupConfirm)
                .textContentType(.oneTimeCode)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: setupConfirm) { _ in setupError = nil }
            Button {
                attemptSetup()
            } label: {
                Text("Set Password & Turn On")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .disabled(setupPassword.isEmpty || setupConfirm.isEmpty)
        } header: {
            Text("Set a Password")
        } footer: {
            if let setupError {
                Text(setupError)
                    .foregroundColor(.red)
            } else {
                Text("4 digits, 8 digits, or anything you like - just don't forget it. It's needed to turn Child Mode off later.")
            }
        }
    }

    private func attemptSetup() {
        guard !setupPassword.isEmpty else {
            setupError = "Enter a password first."
            return
        }
        guard setupPassword == setupConfirm else {
            setupError = "Passwords don't match."
            Haptics.error()
            return
        }
        do {
            try ChildModeService.shared.setPassword(setupPassword)
        } catch {
            setupError = "Couldn't save the password. Please try again."
            Haptics.error()
            return
        }
        settingsViewModel.settings.childModeEnabled = true
        settingsViewModel.saveSettings()
        setupPassword = ""
        setupConfirm = ""
        setupError = nil
        hasPassword = true
        Haptics.success()
    }

    // MARK: - Change password (traditional current -> new -> confirm)

    private var changePasswordSection: some View {
        Section {
            SecureField("Current password", text: $currentPassword)
                .textContentType(.oneTimeCode)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: currentPassword) { _ in changeError = nil; changeSucceeded = false }
            SecureField("New password", text: $newPassword)
                .textContentType(.oneTimeCode)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: newPassword) { _ in changeError = nil; changeSucceeded = false }
            SecureField("Confirm new password", text: $newPasswordConfirm)
                .textContentType(.oneTimeCode)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: newPasswordConfirm) { _ in changeError = nil; changeSucceeded = false }
            Button {
                attemptChangePassword()
            } label: {
                Text("Change Password")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .disabled(currentPassword.isEmpty || newPassword.isEmpty || newPasswordConfirm.isEmpty)
        } header: {
            Text("Change Password")
        } footer: {
            if let changeError {
                Text(changeError)
                    .foregroundColor(.red)
            } else if changeSucceeded {
                Text("Password changed.")
                    .foregroundColor(.green)
            }
        }
    }

    private func attemptChangePassword() {
        guard newPassword == newPasswordConfirm else {
            changeError = "New passwords don't match."
            Haptics.error()
            return
        }
        let changed: Bool
        do {
            changed = try ChildModeService.shared.changePassword(current: currentPassword, to: newPassword)
        } catch {
            changeError = "Couldn't save the new password. Please try again."
            Haptics.error()
            return
        }
        guard changed else {
            changeError = "Wrong current password. Nothing changed."
            Haptics.error()
            currentPassword = ""
            return
        }
        currentPassword = ""
        newPassword = ""
        newPasswordConfirm = ""
        changeError = nil
        changeSucceeded = true
        Haptics.success()
    }

    // MARK: - Clear password (full reset to never-configured)

    private var clearPasswordSection: some View {
        Section {
            Button(role: .destructive) {
                clearPassword = ""
                clearError = nil
                showClearPrompt = true
            } label: {
                Text("Clear Password")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
        } footer: {
            Text("Deletes the Child Mode password and turns Child Mode off, returning it to a never-set-up state. Requires the current password.")
        }
    }

    /// Same manual-password-entry pattern as the toggle-off sheet: one entry, wrong password =
    /// error and nothing happens, never biometrics.
    private var clearSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $clearPassword)
                        .textContentType(.oneTimeCode)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .onChange(of: clearPassword) { _ in clearError = nil }
                } header: {
                    Text("Clear Password")
                } footer: {
                    if let clearError {
                        Text(clearError)
                            .foregroundColor(.red)
                    } else {
                        Text("Enter the Child Mode password to delete it and turn Child Mode off.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        attemptClear()
                    } label: {
                        Text("Clear Password")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .disabled(clearPassword.isEmpty)
                }
            }
            .navigationTitle("Child Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        showClearPrompt = false
                    }
                }
            }
        }
    }

    private func attemptClear() {
        let cleared: Bool
        do {
            cleared = try ChildModeService.shared.clearConfiguration(current: clearPassword)
        } catch {
            clearError = "Couldn't clear the password. Please try again."
            Haptics.error()
            return
        }
        guard cleared else {
            clearError = "Wrong password. Nothing changed."
            Haptics.error()
            clearPassword = ""
            return
        }
        // The service already flipped the persisted flag off through AppSettings.save (so push
        // re-registration and the dock gating have reacted); mirror it into this view model,
        // whose settingsDidChange observer deliberately ignores save notifications.
        settingsViewModel.settings.childModeEnabled = false
        settingsViewModel.saveSettings()
        // Reset every flow's scratch state - the screen drops back to first-time setup.
        currentPassword = ""
        newPassword = ""
        newPasswordConfirm = ""
        changeError = nil
        changeSucceeded = false
        clearPassword = ""
        clearError = nil
        hasPassword = false
        showClearPrompt = false
        Haptics.success()
    }

    // MARK: - Explainer

    private var aboutSection: some View {
        Section {
            Label("Chats & Group Chats", systemImage: "bubble.left.and.bubble.right")
            Label("Portfolio", systemImage: "chart.pie")
            Label("Cold Storage", systemImage: "lock.shield")
        } header: {
            Text("What stays available")
        } footer: {
            Text("While Child Mode is on, Swaps, KaPosts and Broadcasts are removed everywhere - the dock, the Chats-tab cycle, links and notifications. Face ID never unlocks Child Mode; only the password does.")
        }
    }
}

#Preview {
    NavigationStack {
        ChildModeSettingsView()
            .environmentObject(SettingsViewModel())
    }
}
