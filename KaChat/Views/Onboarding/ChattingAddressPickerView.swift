import SwiftUI

/// "Change Chatting Address" scanner, pushed inside the Welcome Guide's NavigationStack from the
/// funding step - import runs only (see `WalletManager.justImportedWallet`). Scans the identity
/// derivation chain (m/44'/111111'/0'/0/<index>) in batches of 50, checking every derived address
/// in batch for KAS balance (one pooled `getUtxosByAddresses` call) and KNS domains (the
/// `KNSService.refreshIfNeeded` capped batch lookup), then lists only the interesting slots:
/// nonzero balance or at least one domain, plus always index 0. Tapping a row opens a detail
/// sheet with the full address, balance and domain cards, and a "Set as Chatting Address" button
/// that performs the clean identity switch (`WalletManager.setChattingAddress`) and pops back to
/// the funding step, which re-renders with the new address.
struct ChattingAddressPickerView: View {
    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [ChattingAddressCandidate] = []
    @State private var scannedCount = 0
    @State private var isScanning = false
    @State private var scanFailed = false
    @State private var selectedCandidate: ChattingAddressCandidate?

    private let batchSize = 50

    /// Identity switching is a clean selection only - never allowed once any conversation
    /// exists (an imported seed with live chats at index 0 must keep that identity).
    /// `setChattingAddress` re-enforces this guard; here it drives the explanatory banner.
    private var conversationsExist: Bool {
        !ChatService.shared.conversations.isEmpty
    }

    private var currentIndex: Int {
        walletManager.currentChattingAddressIndex
    }

    private var visibleCandidates: [ChattingAddressCandidate] {
        candidates.filter {
            $0.balanceSompi > 0 || !$0.domains.isEmpty || $0.index == 0 || $0.index == currentIndex
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(systemName: "person.text.rectangle")
                        .font(.system(size: 44))
                        .foregroundColor(.accentColor)
                    Text("Choose Your Chatting Address")
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("If this seed already holds your identity at a different address - a KNS domain or a funded chatting balance - pick it here. Only addresses with a balance or domains are shown.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                if conversationsExist {
                    Text("This account already has conversations, so its chatting address can no longer be changed.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 10) {
                    ForEach(visibleCandidates) { candidate in
                        candidateRow(candidate)
                    }
                }

                if scanFailed {
                    Text("Could not derive addresses from this seed. Please try again.")
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                if isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning addresses \(scannedCount + 1) to \(scannedCount + batchSize)...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if scannedCount > 0 {
                    VStack(spacing: 6) {
                        Text("Scanned the first \(scannedCount) addresses.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button {
                            Task { await scanNextBatch() }
                        } label: {
                            Label("Scan Further", systemImage: "magnifyingglass")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .navigationTitle("Chatting Address")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCandidate) { candidate in
            ChattingAddressDetailView(
                candidate: candidate,
                isCurrent: candidate.index == currentIndex,
                conversationsExist: conversationsExist,
                onSet: {
                    // Sheet down, picker popped: land back on the funding step, which now
                    // shows the newly chosen address (it reads the live currentWallet).
                    selectedCandidate = nil
                    dismiss()
                }
            )
        }
        .task {
            guard scannedCount == 0, !isScanning else { return }
            await scanNextBatch()
        }
    }

    private func candidateRow(_ candidate: ChattingAddressCandidate) -> some View {
        Button {
            selectedCandidate = candidate
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text("#\(candidate.index)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundColor(.accentColor)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.shortAddress)
                        .font(.footnote.monospaced())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(formatKas(candidate.balanceSompi)) KAS")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !candidate.domains.isEmpty {
                            Text(candidate.domains.count == 1
                                 ? candidate.domains[0].fullName
                                 : "\(candidate.domains.count) domains")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if candidate.index == currentIndex {
                    Text("Current")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.accentColor)
                } else if candidate.index == 0 {
                    Text("Default")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func scanNextBatch() async {
        guard !isScanning else { return }
        isScanning = true
        scanFailed = false
        let range = scannedCount..<(scannedCount + batchSize)
        if let batch = await walletManager.scanChattingAddressCandidates(indices: range) {
            candidates.append(contentsOf: batch)
            scannedCount = range.upperBound
        } else {
            scanFailed = true
        }
        isScanning = false
    }

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Detail sheet for one scanned identity slot: full address (tap to copy), balance, KNS domains
/// rendered with the app's standard `KNSDomainCard` style, and the prominent
/// "Set as Chatting Address" action at the bottom.
struct ChattingAddressDetailView: View {
    let candidate: ChattingAddressCandidate
    let isCurrent: Bool
    let conversationsExist: Bool
    let onSet: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSwitching = false
    @State private var errorMessage: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text("Address #\(candidate.index)")
                            .font(.headline)
                        Button {
                            UIPasteboard.general.string = candidate.address
                            Haptics.success()
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Text(candidate.address)
                                .font(.footnote.monospaced())
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        Text(copied ? "Copied to clipboard" : "Tap the address to copy it")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("Balance", systemImage: "circlebadge.2.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(formatKas(candidate.balanceSompi)) KAS")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    if !candidate.domains.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("KNS Domains (\(candidate.domains.count))")
                                .font(.subheadline.weight(.semibold))
                            ForEach(candidate.domains) { domain in
                                KNSDomainCard(
                                    domain: domain,
                                    isPrimary: isPrimaryDomain(domain)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await setAsChattingAddress() }
                } label: {
                    HStack(spacing: 8) {
                        if isSwitching {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isCurrent ? "Current Chatting Address" : "Set as Chatting Address")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(setButtonDisabled ? Color(.systemGray4) : Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(setButtonDisabled)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("Chatting Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(isSwitching)
                }
            }
            .interactiveDismissDisabled(isSwitching)
        }
    }

    private var setButtonDisabled: Bool {
        isCurrent || conversationsExist || isSwitching
    }

    private func isPrimaryDomain(_ domain: KNSDomain) -> Bool {
        guard let primary = candidate.primaryDomain else { return false }
        return domain.fullName.lowercased() == primary.lowercased()
    }

    private func setAsChattingAddress() async {
        guard !setButtonDisabled else { return }
        isSwitching = true
        errorMessage = nil
        do {
            try await WalletManager.shared.setChattingAddress(index: candidate.index)
            Haptics.success()
            isSwitching = false
            onSet()
        } catch {
            errorMessage = error.localizedDescription
            isSwitching = false
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
