import SwiftUI

/// A password entry field with a trailing eye toggle to show/hide what's being typed.
///
/// Renders a `SecureField` and a `TextField` stacked with opacity swapping (both stay mounted,
/// bound to the same text) so toggling doesn't rebuild the row; an `@FocusState` handoff moves
/// focus to the newly-visible twin on toggle, which keeps the keyboard up instead of dropping
/// it (the closest SwiftUI gets to a true in-place secure/plain switch). Both states disable
/// autocorrection/autocapitalization and use `.oneTimeCode` content type to keep the
/// password-manager banner out of the way, matching how the app's password fields were already
/// configured.
///
/// Used by every Child Mode password field (wizard step, setup/change/turn-off/clear flows)
/// and the Nextcloud app-password field. Bring your own outer styling - this is just the
/// field + eye, so it drops into a Form row or a padded/rounded wizard box equally.
struct RevealableSecureField: View {
    let titleKey: LocalizedStringKey
    @Binding var text: String

    @State private var revealed = false
    @FocusState private var focusedField: FieldKind?

    private enum FieldKind: Hashable {
        case secure
        case plain
    }

    init(_ titleKey: LocalizedStringKey, text: Binding<String>) {
        self.titleKey = titleKey
        self._text = text
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                SecureField(titleKey, text: $text)
                    .textContentType(.oneTimeCode)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .secure)
                    .opacity(revealed ? 0 : 1)
                    .allowsHitTesting(!revealed)
                TextField(titleKey, text: $text)
                    .textContentType(.oneTimeCode)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .plain)
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
            }

            Button {
                let hadFocus = focusedField != nil
                revealed.toggle()
                if hadFocus {
                    // Hand focus to the now-visible twin on the next runloop turn (setting it
                    // in the same update as the opacity flip loses the keyboard).
                    DispatchQueue.main.async {
                        focusedField = revealed ? .plain : .secure
                    }
                }
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            // Borderless keeps the tap target on the icon itself instead of letting a Form row
            // swallow the whole-row tap.
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "Hide password" : "Show password")
        }
    }
}
