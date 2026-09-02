import SwiftUI

/// Thousands grouping for a number the user is typing.
///
/// A decimal keypad gives you digits and nothing else, so a six-figure hashrate arrives as
/// "1200000" and has to be counted by eye. This regroups after every keystroke and hands the
/// value back ungrouped when something needs to compute with it.
enum DecimalInputFormat {
    /// The locale's grouping and decimal separators, so "1.234,5" is right where that is right.
    private static var grouping: String {
        Locale.current.groupingSeparator ?? ","
    }

    private static var decimal: String {
        Locale.current.decimalSeparator ?? "."
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    /// `text` with grouping separators put back where they belong.
    ///
    /// The fractional part is left exactly as typed - grouping it means nothing, and reformatting
    /// it would fight the user over trailing zeros and a lone separator mid-entry ("1." has to
    /// survive long enough to become "1.5").
    static func grouped(_ text: String) -> String {
        // Accept either separator as the decimal point: a keypad emits the device locale's, and
        // pasted text may carry the other.
        let normalized = text.replacingOccurrences(of: grouping, with: "")
        let parts = normalized.split(separator: Character(decimal), maxSplits: 1,
                                     omittingEmptySubsequences: false)
        guard let whole = parts.first else { return text }

        let digits = whole.filter(\.isNumber)
        guard !digits.isEmpty else { return normalized }
        guard let number = Decimal(string: String(digits)),
              let formatted = formatter.string(from: number as NSDecimalNumber) else {
            return normalized
        }

        if parts.count > 1 {
            return formatted + decimal + String(parts[1])
        }
        // A trailing separator the user has just typed must survive, or the next digit can never
        // become a fraction.
        return normalized.hasSuffix(decimal) ? formatted + decimal : formatted
    }

    /// The number behind grouped text, or nil when there isn't one yet.
    static func value(_ text: String) -> Double? {
        let bare = text
            .replacingOccurrences(of: grouping, with: "")
            .replacingOccurrences(of: decimal, with: ".")
            // Whichever separator the locale did NOT claim is still a decimal point to a user
            // who typed it.
            .replacingOccurrences(of: ",", with: ".")
        return Double(bare)
    }
}

/// A "done" button over a numeric keyboard.
///
/// `.decimalPad` and `.numberPad` have no return key, so the only way off them is a tap outside
/// the field - which on a form crowded with other controls means tapping something you did not
/// mean to. This puts a real dismiss button on the keyboard itself.
struct NumericKeyboardDoneButton: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        isFocused = false
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("Done editing")
                }
            }
    }
}

extension View {
    /// Adds a checkmark to the numeric keyboard that dismisses it. See
    /// `NumericKeyboardDoneButton`.
    func numericKeyboardDoneButton() -> some View {
        modifier(NumericKeyboardDoneButton())
    }
}
