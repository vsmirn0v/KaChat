import SwiftUI
import UIKit

// The pieces every Send Kaspa screen is built from, so they look and behave the same: the 1:1
// chat's Send KAS sheet, Profile's Send Kaspa, a spending address's Send, and KasSigner's send.
// Recipient on top (paste, scan a QR, names resolve), then the big amount (KAS or your currency,
// Max), the fee and balance, the fee speed and coin control, and a slide-to-send button.

/// The frosted card the Send Kaspa pieces sit on.
func sendKaspaGlass(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
}

// MARK: - Recipient

/// Who the Kaspa goes to: an address or a name, with Paste and Scan QR beside the field and a
/// line saying what the input resolved to. The screen keeps its own lookup logic (it watches
/// `input`); this only shows it. With `lockedAddress` (Compound UTXOs) the recipient is fixed.
struct SendRecipientCard: View {
    @Binding var input: String
    var lockedAddress: String? = nil
    let isResolving: Bool
    let resolvedAddress: String?
    let resolvedName: String?
    let lookupError: String?
    let isValidAddress: Bool
    let onScan: () -> Void

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("To")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if let lockedAddress {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundColor(.accentColor)
                    Text(verbatim: lockedAddress)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Consolidating This Address")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 14) {
                    TextField("kaspa:qr... or domain", text: $input)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            input = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel(Text("Paste"))
                    Button(action: onScan) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel(Text("Scan QR"))
                }
                AddressResolutionCard(address: resolvedAddress ?? (isValidAddress ? trimmed : nil), domain: resolvedName)
                if !trimmed.isEmpty {
                    statusLine
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 20))
    }

    @ViewBuilder
    private var statusLine: some View {
        if isResolving {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text("Looking up domain...")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        } else if let lookupError {
            Label(lookupError, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
        } else if let resolvedAddress {
            VStack(alignment: .leading, spacing: 2) {
                Label("Resolved: \(resolvedName ?? "")", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text(verbatim: resolvedAddress)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Label(isValidAddress ? "Valid address" : "Invalid address format",
                  systemImage: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(isValidAddress ? .green : .red)
        }
    }
}

// MARK: - Amount

/// The big centred amount and its unit, with the KAS / your-currency switch (showing the
/// converted value) and Max under it. Hands the screen the KAS amount text after every edit.
struct KaspaAmountEntry: View {
    @ObservedObject var fiatAmountState: KaspaFiatAmountState
    @ObservedObject private var portfolio = PortfolioViewModel.shared
    /// Receives the amount in KAS (as text) after each edit - what the screen stores.
    let onAmountChange: (String) -> Void
    /// Cleans what was typed before it's used (the chat sheet drops stray characters).
    var sanitize: (String) -> String = { $0 }
    var isEstimatingMax = false
    var maxEnabled = true
    /// Puts the cursor in the amount when the screen appears (the amount is the first thing to type).
    var focusOnAppear = false
    let onMax: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        let display = fiatAmountState.displayText
        let fontSize: CGFloat = display.count <= 7 ? 52 : (display.count <= 10 ? 40 : 30)
        let price = portfolio.currentPriceUsd
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(
                    "0",
                    text: Binding(
                        get: { fiatAmountState.displayText },
                        set: { newValue in
                            onAmountChange(fiatAmountState.onDisplayTextChange(sanitize(newValue), priceInCurrency: price))
                        }
                    )
                )
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .keyboardType(.decimalPad)
                .fixedSize()
                .focused($isFocused)
                .accessibilityLabel(Text(KaspaUnit.label(AppLocalization.string("Amount (KAS)"))))

                Text(verbatim: fiatAmountState.isFiatMode ? portfolio.currentCurrency.code : KaspaUnit.symbol)
                    .font(.system(size: fontSize * 0.55, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            HStack(spacing: 10) {
                if price != nil {
                    Button {
                        fiatAmountState.toggleMode(priceInCurrency: price)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption.weight(.semibold))
                            if let conversion = fiatAmountState.conversionLabelText(priceInCurrency: price, currency: portfolio.currentCurrency) {
                                Text(verbatim: conversion)
                            } else {
                                Text(verbatim: fiatAmountState.isFiatMode ? KaspaUnit.symbol : portfolio.currentCurrency.code)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(sendKaspaGlass(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch between Kaspa and your currency"))
                }

                Button(action: onMax) {
                    Group {
                        if isEstimatingMax {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Max")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(sendKaspaGlass(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!maxEnabled || isEstimatingMax)
                .opacity(maxEnabled ? 1 : 0.5)
            }
        }
        .onAppear {
            guard focusOnAppear else { return }
            // The field doesn't exist yet on the tap that presented the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isFocused = true }
        }
    }
}

// MARK: - Fee and coin control

/// Network fee (tap to set a custom one), the fee speed, and coin control - one card.
struct SendFeeControls: View {
    @Binding var feeTier: WithdrawFeeTier
    @Binding var isEditingFee: Bool
    @Binding var customFeeText: String
    let isEstimatingFee: Bool
    /// The fee as shown ("0.0001 KAS"), nil while unknown.
    let feeText: String?
    let onStartEditing: () -> Void
    let onCommit: () -> Void
    var showsCoinControl = true
    var coinControlSummary: String = ""
    var onCoinControl: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Network Fee")
                    .font(.subheadline)
                Spacer()
                if isEditingFee {
                    TextField("0.00", text: $customFeeText)
                        .keyboardType(.decimalPad)
                        .numericKeyboardDoneButton()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .onSubmit(onCommit)
                    Button(action: onCommit) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                } else if isEstimatingFee {
                    ProgressView().scaleEffect(0.75)
                } else if let feeText {
                    Button(action: onStartEditing) {
                        HStack(spacing: 4) {
                            Text(verbatim: feeText).underline()
                            Image(systemName: "pencil").font(.caption2)
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(verbatim: "—").foregroundColor(.secondary)
                }
            }
            Picker("Fee", selection: $feeTier) {
                ForEach(WithdrawFeeTier.allCases) { tier in
                    Text(LocalizedStringKey(tier.rawValue)).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            Text("If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Tap the fee amount to set a custom fee.")
                .font(.caption)
                .foregroundColor(.secondary)

            if showsCoinControl {
                Divider()
                Button(action: onCoinControl) {
                    HStack {
                        Text("Coin Control")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: coinControlSummary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(sendKaspaGlass(cornerRadius: 20))
    }
}

/// "Automatic" or "3 UTXOs selected", for the coin control row.
func coinControlSummary(_ manualUtxos: [UTXO]?) -> String {
    guard let manualUtxos else { return AppLocalization.string("Automatic") }
    return "\(manualUtxos.count) UTXO\(manualUtxos.count == 1 ? "" : "s") selected"
}

/// A small glass capsule for one line of context (available balance, fee).
struct SendInfoPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(sendKaspaGlass(cornerRadius: 14))
    }
}

// MARK: - Send button

/// The send button: slide the knob to the right end to send, so a payment can't go out on a
/// stray touch. Letting go before the end springs it back; after a send that didn't go through
/// (an error, the small-amount question) it resets by itself. VoiceOver gets a plain activate
/// action. With `requiresSlide: false` it's an ordinary tap in the same look (KasSigner's "Build
/// Unsigned Transaction", which moves nothing by itself).
struct SendActionButton: View {
    let title: LocalizedStringKey
    let isBusy: Bool
    let isEnabled: Bool
    var requiresSlide = true
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var reachedEnd = false
    private let height: CGFloat = 56
    private let inset: CGFloat = 4

    private var active: Bool { isEnabled && !isBusy }

    var body: some View {
        Group {
            if requiresSlide {
                slider
            } else {
                track(progress: 0)
                    .overlay {
                        label.frame(maxWidth: .infinity)
                    }
                    .onTapGesture {
                        guard active else { return }
                        action()
                    }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard active else { return }
            action()
        }
        .onChange(of: isBusy) { busy in
            if !busy { reset() }
        }
    }

    private var slider: some View {
        GeometryReader { geometry in
            let knob = height - inset * 2
            let maxOffset = max(1, geometry.size.width - knob - inset * 2)
            let progress = min(1, offset / maxOffset)
            ZStack(alignment: .leading) {
                track(progress: progress, knob: knob)
                label
                    .opacity(isBusy ? 1 : Double(1 - progress))
                    .frame(maxWidth: .infinity)
                if !isBusy {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .overlay(
                            Image(systemName: "chevron.right.2")
                                .font(.headline.weight(.bold))
                                .foregroundColor(Color.accentColor)
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                        .offset(x: inset + offset)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard active else { return }
                                    if offset == 0 && value.translation.width > 0 { Haptics.impact(.light) }
                                    offset = min(max(0, value.translation.width), maxOffset)
                                    if offset >= maxOffset && !reachedEnd {
                                        reachedEnd = true
                                        Haptics.impact(.medium)
                                    } else if offset < maxOffset {
                                        reachedEnd = false
                                    }
                                }
                                .onEnded { _ in
                                    guard active else { return }
                                    if offset >= maxOffset * 0.95 {
                                        offset = maxOffset
                                        action()
                                        // A send that didn't start (dust question, a validation
                                        // error) leaves it not busy: put the knob back.
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                            if !isBusy { reset() }
                                        }
                                    } else {
                                        reset()
                                    }
                                }
                        )
                }
            }
        }
    }

    private func track(progress: CGFloat, knob: CGFloat = 0) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor.opacity(isEnabled || isBusy ? 1 : 0.4))
            if knob > 0 {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: inset * 2 + knob + offset)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().tint(.black)
            } else {
                Text(title).font(.headline)
            }
        }
        .foregroundColor(.black)
    }

    private func reset() {
        reachedEnd = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { offset = 0 }
    }
}
