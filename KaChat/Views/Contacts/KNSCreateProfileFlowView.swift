import SwiftUI
import PhotosUI
import ImageIO

/// Matches the same-named `private` helper duplicated per-file elsewhere in this codebase
/// (ContactsView.swift, ChatInfoView.swift) rather than sharing across files for one line.
private func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
    String(format: AppLocalization.string(key), locale: AppLocalization.locale, arguments: args)
}

/// Guided, step-by-step flow for a wallet that doesn't own a KNS domain yet: fund-check gate ->
/// register a domain (real on-chain commit/reveal inscription) -> optional banner -> optional
/// avatar -> optional bio/social details -> finished. Every write here goes through the same
/// services the existing (edit-an-existing-profile) `KNSProfileEditorSheet` uses
/// (`KNSDomainInscribeService`, `KNSProfileWriteService`, `KNSService.uploadProfileImage`) - this
/// view is purely new orchestration/UX around already-working inscription machinery, not a new
/// protocol implementation.
struct KNSCreateProfileFlowView: View {
    let walletAddress: String
    /// Non-nil when re-entering via "Setup Guide" on an already-registered profile - lets the
    /// domain step offer skipping past registration, and lets the banner/avatar/details steps
    /// show what's already inscribed so the user is reviewing/updating rather than starting blank.
    let existingProfile: KNSAddressProfileInfo?
    let onFinished: () -> Void

    private enum Step: Equatable {
        case checkingFunds
        case needsFunding(balanceKas: Decimal)
        case domain
        case transferExistingDomain
        case domainConfirmed(domain: String)
        case banner
        case avatar
        case details
        case finished
    }

    /// Fixed UX gate, not derived from live KNS fee tiers - deliberately generous relative to a
    /// domain's actual commit+reveal cost so the flow doesn't fail partway through from
    /// insufficient funds once the user's already invested time in it.
    private static let minimumFundingBalanceKas: Decimal = 50

    @State private var step: Step = .checkingFunds
    @State private var assetId: String?
    @State private var domainName: String?
    @State private var fundingCheckError: String?
    @State private var currentBalanceSompi: UInt64?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()

    init(walletAddress: String, existingProfile: KNSAddressProfileInfo? = nil, onFinished: @escaping () -> Void) {
        self.walletAddress = walletAddress
        self.existingProfile = existingProfile
        self.onFinished = onFinished
        _assetId = State(initialValue: existingProfile?.assetId)
        _domainName = State(initialValue: existingProfile?.domainName)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Create KNS Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { onFinished() }
                    }
                }
        }
        .toast(message: toastMessage)
        .task {
            await checkFunding()
        }
    }

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

    @ViewBuilder
    private var content: some View {
        switch step {
        case .checkingFunds:
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking your chatting address balance...")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .needsFunding(let balanceKas):
            fundingGateView(balanceKas: balanceKas)

        case .domain:
            KNSDomainCreationStepView(
                walletAddress: walletAddress,
                existingDomain: existingProfile?.domainName,
                onSkipped: { domain in
                    // Asset id for an already-registered domain is already known from
                    // `existingProfile` (seeded at init) - no refetch needed, unlike a fresh
                    // inscribe below.
                    domainName = domain
                    step = .domainConfirmed(domain: domain)
                },
                onInscribed: { result in
                    domainName = result.domain
                    Task {
                        // `inscribeDomain` already refreshes KNSService's caches internally, so
                        // this resolves the asset id it just created without a redundant network
                        // round trip being visible to the user as a separate loading state.
                        let profileInfo = await KNSService.shared.fetchProfile(for: walletAddress)
                        await MainActor.run {
                            assetId = profileInfo?.assetId
                            step = .domainConfirmed(domain: result.domain)
                        }
                    }
                },
                onTransferExisting: { step = .transferExistingDomain }
            )

        case .transferExistingDomain:
            transferExistingDomainView

        case .domainConfirmed(let domain):
            domainConfirmedView(domain: domain)

        case .banner:
            KNSImageInscribeStepView(
                title: "Let's set up a profile banner",
                subtitle: "Add a banner image to your profile, or skip for now.",
                assetId: assetId ?? "",
                domainName: domainName,
                uploadType: .banner,
                fieldKey: .bannerUrl,
                existingImageURL: existingProfile?.profile?.bannerUrl,
                onDone: { step = .avatar }
            )

        case .avatar:
            KNSImageInscribeStepView(
                title: "Let's inscribe your avatar photo",
                subtitle: "Add a profile photo, or skip for now.",
                assetId: assetId ?? "",
                domainName: domainName,
                uploadType: .avatar,
                fieldKey: .avatarUrl,
                existingImageURL: existingProfile?.profile?.avatarUrl,
                onDone: { step = .details }
            )

        case .details:
            KNSDetailsStepView(
                assetId: assetId ?? "",
                domainName: domainName,
                existingProfile: existingProfile?.profile,
                onDone: { step = .finished }
            )

        case .finished:
            finishedView
        }
    }

    private func checkFunding() async {
        do {
            let utxos = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
            let sompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            let kas = Decimal(sompi) / 100_000_000
            currentBalanceSompi = sompi
            fundingCheckError = nil
            if kas >= Self.minimumFundingBalanceKas {
                step = .domain
            } else {
                step = .needsFunding(balanceKas: kas)
            }
        } catch {
            fundingCheckError = error.localizedDescription
            step = .needsFunding(balanceKas: 0)
        }
    }

    private func fundingGateView(balanceKas: Decimal) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text(localizedFormat("Please fund your chatting address with at least %@ Kaspa to continue.", Self.formatKas(Self.minimumFundingBalanceKas)))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 4) {
                Text("Current balance")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(Self.formatKas(balanceKas)) KAS")
                    .font(.title2.weight(.bold))
            }

            VStack(spacing: 4) {
                Text("Chatting address")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    UIPasteboard.general.string = walletAddress
                    Haptics.success()
                    showToast(walletAddress.addressCopiedToastText)
                } label: {
                    Text(walletAddress)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }

            // Reuses the same white-background QR view every other "receive" surface in the
            // app uses (Profile tab's Accept Kaspa/Chatting Address buttons) rather than a
            // one-off, so someone with a second device - or helping in person - can scan and
            // send right from this screen.
            NavigationLink {
                ChattingAddressQRView(
                    address: walletAddress,
                    balanceSompi: currentBalanceSompi,
                    subtitle: "Send around \(Self.formatKas(Self.minimumFundingBalanceKas)) Kaspa to this address to have enough for full KNS profile creation and chatting for a while"
                )
            } label: {
                Label("Show QR Code", systemImage: "qrcode")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.top, 4)

            if let fundingCheckError {
                Text(fundingCheckError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                step = .checkingFunds
                Task { await checkFunding() }
            } label: {
                Text("Check Again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, existingProfile?.domainName?.isEmpty == false ? 0 : 24)

            // Escape hatch for someone re-entering via "Setup Guide" whose domain is already
            // registered - the funding gate exists to protect a *new* domain inscription, which
            // they don't need, so this skips straight past it to the domain step (which itself
            // offers "Skip - Continue with <existing domain>" once there). Only shown when a
            // domain is already known: the fresh "Create KNS Profile" entry point never has one,
            // since that button itself only appears when there's no domain yet.
            if existingProfile?.domainName?.isEmpty == false {
                Button {
                    step = .domain
                } label: {
                    Text("It's ok, I already have a domain")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 24)
            }
        }
    }

    /// Reached from the domain step's "I already have a domain somewhere else" button - for a
    /// domain already registered on another wallet/service, there's nothing this flow itself can
    /// do here (no inscribe, no polling for a transfer that happens entirely off-app), so this
    /// just shows the address to transfer to, then continues the flow on to the banner/avatar/
    /// details steps rather than ending it - the domain being handled off-app doesn't mean the
    /// rest of the profile isn't still worth setting up.
    private var transferExistingDomainView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("Transfer Your Domain")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("Transfer your domain to this address so that your identity is connected to KaChat.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 4) {
                Text("Chatting address")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    UIPasteboard.general.string = walletAddress
                    Haptics.success()
                    showToast(walletAddress.addressCopiedToastText)
                } label: {
                    Text(walletAddress)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }

            NavigationLink {
                ChattingAddressQRView(
                    address: walletAddress,
                    balanceSompi: nil,
                    subtitle: "Transfer your domain to this address so that your identity is connected to KaChat."
                )
            } label: {
                Label("Show QR Code", systemImage: "qrcode")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.top, 4)

            Spacer()

            Button {
                step = .banner
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

    private func domainConfirmedView(domain: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text(localizedFormat("You are now known as %@", domain))
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            Button {
                step = .banner
            } label: {
                Text("Continue")
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

    private var finishedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "party.popper.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("You have now finished your KNS profile creation!")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            Button {
                onFinished()
            } label: {
                Text("Done")
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

    fileprivate static func formatKas(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}

// MARK: - Step 1: Domain creation

/// Mirrors `KNSDomainInscribeSheet`'s availability-check/fee/submit logic (ContactsView.swift),
/// restyled as a full-screen wizard step instead of a form sheet.
private struct KNSDomainCreationStepView: View {
    let walletAddress: String
    let existingDomain: String?
    let onSkipped: (String) -> Void
    let onInscribed: (KNSDomainInscribeResult) -> Void
    let onTransferExisting: () -> Void

    @State private var domainInput = ""
    @State private var feeTiers: [Int: Decimal] = [:]
    @State private var availability: KNSDomainAvailability?
    @State private var isCheckingAvailability = false
    @State private var isSubmitting = false
    @State private var feeError: String?
    @State private var checkError: String?
    @State private var submitError: String?
    @State private var checkTask: Task<Void, Never>?

    private var normalizedLabel: String? {
        KNSService.shared.normalizeDomainLabel(domainInput)
    }

    private var fullDomain: String? {
        guard let normalizedLabel else { return nil }
        return "\(normalizedLabel).kas"
    }

    private var currentServiceFeeKas: Decimal? {
        guard let label = normalizedLabel, !feeTiers.isEmpty else { return nil }
        if availability?.isReservedDomain == true { return 0 }
        let tier = min(max(label.count, 1), 5)
        return feeTiers[tier] ?? feeTiers[5]
    }

    private var canSubmit: Bool {
        guard !isSubmitting, !isCheckingAvailability else { return false }
        guard normalizedLabel != nil else { return false }
        guard availability?.available == true else { return false }
        return currentServiceFeeKas != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("First let's create your identity with a domain name")
                    .font(.title2.weight(.bold))
                    .padding(.top, 12)

                Button {
                    onTransferExisting()
                } label: {
                    Text("I already have a domain somewhere else")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("name", text: $domainInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onChange(of: domainInput) { _ in
                            scheduleAvailabilityCheck()
                        }

                    if let fullDomain {
                        Text(fullDomain)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Use lowercase letters, numbers, and hyphen.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if isCheckingAvailability {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("Checking availability...")
                                .foregroundColor(.secondary)
                        }
                    } else if let checkError, !checkError.isEmpty {
                        Text(checkError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    } else if let availability {
                        Text(
                            availability.available
                            ? localizedFormat("%@ can be inscribed.", availability.domain)
                            : String(localized: "This domain is not available.")
                        )
                        .font(.footnote)
                        .foregroundColor(availability.available ? .green : .red)
                    }
                }

                if let fee = currentServiceFeeKas {
                    HStack {
                        Text("Service fee")
                        Spacer()
                        Text("\(KNSCreateProfileFlowView.formatKas(fee)) KAS")
                            .foregroundColor(.secondary)
                    }
                }
                if let feeError, !feeError.isEmpty {
                    Text(feeError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                if isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Submitting inscription... this could take a few minutes while it confirms on-chain.")
                            .foregroundColor(.secondary)
                    }
                }
                if let submitError, !submitError.isEmpty {
                    Text(submitError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                Spacer(minLength: 20)

                Button {
                    submitInscribe()
                } label: {
                    Text("Inscribe Domain")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canSubmit ? Color.accentColor : Color(.systemGray4))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!canSubmit)

                if let existingDomain {
                    Button {
                        onSkipped(existingDomain)
                    } label: {
                        Text(localizedFormat("Skip - Continue with %@", existingDomain))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isSubmitting)
                }
            }
            .padding(24)
        }
        .task {
            await loadFeeTiers()
        }
        .onDisappear {
            checkTask?.cancel()
        }
    }

    private func loadFeeTiers() async {
        do {
            feeTiers = try await KNSService.shared.fetchInscribeFeeTiers()
            feeError = nil
        } catch {
            feeError = error.localizedDescription
        }
    }

    private func scheduleAvailabilityCheck() {
        checkTask?.cancel()
        submitError = nil
        availability = nil

        let raw = domainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            checkError = nil
            isCheckingAvailability = false
            return
        }
        guard let label = normalizedLabel else {
            checkError = String(localized: "Use lowercase letters, numbers, and hyphen.")
            isCheckingAvailability = false
            return
        }

        checkError = nil
        isCheckingAvailability = true
        let full = "\(label).kas"
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await KNSService.shared.checkDomainAvailability(address: walletAddress, domainName: full)
                guard !Task.isCancelled else { return }
                availability = result
                isCheckingAvailability = false
                checkError = nil
            } catch {
                guard !Task.isCancelled else { return }
                availability = nil
                isCheckingAvailability = false
                checkError = error.localizedDescription
            }
        }
    }

    private func submitInscribe() {
        guard let label = normalizedLabel else {
            submitError = String(localized: "Invalid domain label")
            return
        }
        isSubmitting = true
        submitError = nil
        Task {
            do {
                let result = try await KNSDomainInscribeService.shared.inscribeDomain(label: label)
                await MainActor.run {
                    isSubmitting = false
                    Haptics.success()
                    onInscribed(result)
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    submitError = error.localizedDescription
                    Haptics.impact(.medium)
                }
            }
        }
    }
}

// MARK: - Steps 2/3: Banner/avatar image inscription

/// Shared shape for both the banner and avatar steps - pick a photo, inscribe it (upload + write
/// the `avatarUrl`/`bannerUrl` profile field via commit/reveal), or skip.
private struct KNSImageInscribeStepView: View {
    let title: String
    let subtitle: String
    let assetId: String
    let domainName: String?
    let uploadType: KNSProfileImageUploadType
    let fieldKey: KNSProfileFieldKey
    /// The currently-inscribed image, if re-entering on a profile that already has one - shown
    /// as the starting preview so the user is reviewing/replacing rather than starting blank.
    /// Only ever a display fallback: picking a new photo always takes over the preview, and the
    /// "Inscribe" button stays gated on a *new* pick (`uploadData`), so just viewing this without
    /// changing it never triggers a pointless resubmission.
    let existingImageURL: String?
    let onDone: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var uploadData: Data?
    @State private var uploadMimeType: String?
    @State private var isLoadingImage = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Group {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                    } else if isLoadingImage {
                        ProgressView()
                    } else if let existingImageURL, let url = URL(string: existingImageURL) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                choosePhotoPlaceholder
                            }
                        }
                    } else {
                        choosePhotoPlaceholder
                    }
                }
                .frame(width: 200, height: uploadType == .banner ? 110 : 200)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: uploadType == .banner ? 14 : 100))
            }
            .buttonStyle(.plain)
            .onChange(of: pickerItem) { newValue in
                guard let newValue else { return }
                Task { await loadPickedImage(newValue) }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
            }

            if isSubmitting {
                Text("This could take a few minutes while it confirms on-chain.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    submitInscribe()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        Text("Inscribe")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(uploadData != nil ? Color.accentColor : Color(.systemGray4))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .disabled(uploadData == nil || isSubmitting)

                Button {
                    onDone()
                } label: {
                    Text("Skip")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .disabled(isSubmitting)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var choosePhotoPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 32))
            Text("Choose Photo")
                .font(.subheadline)
        }
        .foregroundColor(.accentColor)
    }

    private func loadPickedImage(_ item: PhotosPickerItem) async {
        await MainActor.run {
            errorMessage = nil
            isLoadingImage = true
        }
        do {
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                throw KasiaError.apiError(String(localized: "Could not load selected image"))
            }
            let prepared = try KNSImagePrep.prepare(rawData)
            await MainActor.run {
                previewImage = prepared.image
                uploadData = prepared.data
                uploadMimeType = prepared.mimeType
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
        await MainActor.run {
            isLoadingImage = false
        }
    }

    private func submitInscribe() {
        guard let uploadData, let uploadMimeType, !assetId.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                let imageURL = try await KNSImageUploadHelper.uploadWithSignatureFallback(
                    assetId: assetId,
                    uploadType: uploadType,
                    imageData: uploadData,
                    mimeType: uploadMimeType
                )
                try await KNSProfileWriteService.shared.submitAddProfile(
                    assetId: assetId,
                    key: fieldKey,
                    value: imageURL,
                    domainName: domainName
                )
                await MainActor.run {
                    isSubmitting = false
                    Haptics.success()
                    onDone()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                    Haptics.impact(.medium)
                }
            }
        }
    }
}

// MARK: - Step 4: Details

private struct KNSDetailsStepView: View {
    let assetId: String
    let domainName: String?
    let onDone: () -> Void

    @State private var bio: String
    @State private var website: String
    @State private var x: String
    @State private var telegram: String
    @State private var discord: String
    @State private var github: String
    @State private var contactEmail: String

    /// Original values at screen-open, so re-entering on an already-filled-in profile only
    /// resubmits (and re-pays for) fields the user actually changed here, not every non-empty one.
    private let existingBio: String
    private let existingWebsite: String
    private let existingX: String
    private let existingTelegram: String
    private let existingDiscord: String
    private let existingGithub: String
    private let existingContactEmail: String

    @State private var isSubmitting = false
    @State private var progressText: String?
    @State private var errorMessage: String?
    @FocusState private var focusedField: KNSProfileFieldKey?

    private enum FieldSubmitStatus: Equatable {
        case submitting
        case done
    }
    @State private var fieldStatuses: [KNSProfileFieldKey: FieldSubmitStatus] = [:]

    /// Flat per-field commit cost - matches `KNSProfileWriteService.submitAddProfile`'s default
    /// commit amount (`KNSService.swift`), which every field/image write uses regardless of key.
    private static let costPerFieldKas: Decimal = 2

    init(assetId: String, domainName: String?, existingProfile: KNSDomainProfile?, onDone: @escaping () -> Void) {
        self.assetId = assetId
        self.domainName = domainName
        self.onDone = onDone
        existingBio = existingProfile?.bio ?? ""
        existingWebsite = existingProfile?.website ?? ""
        existingX = existingProfile?.x ?? ""
        existingTelegram = existingProfile?.telegram ?? ""
        existingDiscord = existingProfile?.discord ?? ""
        existingGithub = existingProfile?.github ?? ""
        existingContactEmail = existingProfile?.contactEmail ?? ""
        _bio = State(initialValue: existingBio)
        _website = State(initialValue: existingWebsite)
        _x = State(initialValue: existingX)
        _telegram = State(initialValue: existingTelegram)
        _discord = State(initialValue: existingDiscord)
        _github = State(initialValue: existingGithub)
        _contactEmail = State(initialValue: existingContactEmail)
    }

    private var fields: [(key: KNSProfileFieldKey, value: String)] {
        [
            (KNSProfileFieldKey.bio, bio, existingBio),
            (.website, website, existingWebsite),
            (.x, x, existingX),
            (.telegram, telegram, existingTelegram),
            (.discord, discord, existingDiscord),
            (.github, github, existingGithub),
            (.contactEmail, contactEmail, existingContactEmail)
        ].compactMap { key, value, existing in
            guard fieldStatuses[key] != .done else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != existing else { return nil }
            return (key, trimmed)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Let's add more details about yourself")
                    .font(.title2.weight(.bold))
                    .padding(.top, 12)
                Text(localizedFormat("You need at least %@ KAS to fill in all fields.", KNSCreateProfileFlowView.formatKas(Self.costPerFieldKas)))
                    .font(.footnote)
                    .foregroundColor(.secondary)

                detailField("Bio", key: .bio, text: $bio, multiline: true)
                detailField("Website", key: .website, text: $website)
                detailField("X (Twitter)", key: .x, text: $x)
                detailField("Telegram", key: .telegram, text: $telegram)
                detailField("Discord", key: .discord, text: $discord)
                detailField("GitHub", key: .github, text: $github)
                detailField("Contact Email", key: .contactEmail, text: $contactEmail)

                if isSubmitting, let progressText {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text(progressText)
                                .foregroundColor(.secondary)
                        }
                        Text("This could take a few minutes while it confirms on-chain.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                Spacer(minLength: 20)

                VStack(spacing: 12) {
                    Button {
                        submitAll()
                    } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isSubmitting)

                    Button {
                        onDone()
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .disabled(isSubmitting)
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture {
            focusedField = nil
        }
    }

    private func detailField(_ label: String, key: KNSProfileFieldKey, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                switch fieldStatuses[key] {
                case .submitting:
                    ProgressView()
                        .scaleEffect(0.7)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                case nil:
                    EmptyView()
                }
            }
            if multiline {
                TextEditor(text: text)
                    .frame(minHeight: 84)
                    .focused($focusedField, equals: key)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                TextField(label, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: key)
                    .padding(12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func submitAll() {
        guard !assetId.isEmpty else {
            onDone()
            return
        }
        let toSubmit = fields
        guard !toSubmit.isEmpty else {
            onDone()
            return
        }
        isSubmitting = true
        errorMessage = nil
        Task {
            for field in toSubmit {
                await MainActor.run {
                    fieldStatuses[field.key] = .submitting
                    progressText = localizedFormat("Inscribing %@...", field.key.displayName)
                }
                do {
                    try await KNSProfileWriteService.shared.submitAddProfile(
                        assetId: assetId,
                        key: field.key,
                        value: field.value,
                        domainName: domainName
                    )
                    await MainActor.run {
                        fieldStatuses[field.key] = .done
                    }
                } catch {
                    await MainActor.run {
                        isSubmitting = false
                        fieldStatuses[field.key] = nil
                        errorMessage = localizedFormat("Failed to inscribe %@: %@", field.key.displayName, error.localizedDescription)
                        Haptics.impact(.medium)
                    }
                    return
                }
            }
            await MainActor.run {
                isSubmitting = false
                Haptics.success()
                onDone()
            }
        }
    }
}

// MARK: - Shared helpers

/// Resizes/encodes a picked photo for KNS upload - mirrors `KNSProfileEditorSheet.prepareImageForUpload`'s
/// approach (that one's `private` to its own file, so this is a small, deliberate duplicate rather
/// than a cross-file share for a ~15-line image-prep routine).
private enum KNSImagePrep {
    static func prepare(_ rawData: Data) throws -> (image: UIImage, data: Data, mimeType: String) {
        let maxDimension: CGFloat = 1400
        guard let source = CGImageSourceCreateWithData(rawData as CFData, nil) else {
            throw KasiaError.apiError(String(localized: "Selected data is not a valid image"))
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw KasiaError.apiError(String(localized: "Could not process selected image"))
        }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw KasiaError.apiError(String(localized: "Could not encode selected image"))
        }
        return (image, data, "image/jpeg")
    }
}

/// Mirrors `ContactsView.uploadProfileImageWithSignatureFallback`'s pattern (also `private` to its
/// own file): sign the upload authorization message, retrying across signing modes if the server
/// rejects the first one as a verification failure.
private enum KNSImageUploadHelper {
    static func uploadWithSignatureFallback(
        assetId: String,
        uploadType: KNSProfileImageUploadType,
        imageData: Data,
        mimeType: String
    ) async throws -> String {
        let signMessage = try await KNSService.shared.buildImageUploadSigningMessage(assetId: assetId, uploadType: uploadType)
        let signingModes: [WalletManager.ArbitraryMessageSigningMode] = [.kaspaPersonalMessage, .rawUTF8, .sha256Digest]

        var lastError: Error?
        for (index, mode) in signingModes.enumerated() {
            let signature = try await WalletManager.shared.signArbitraryMessage(signMessage, mode: mode)
            do {
                return try await KNSService.shared.uploadProfileImage(
                    assetId: assetId,
                    uploadType: uploadType,
                    imageData: imageData,
                    mimeType: mimeType,
                    signMessage: signMessage,
                    signature: signature
                )
            } catch {
                lastError = error
                let hasNextMode = index < (signingModes.count - 1)
                let message = error.localizedDescription.lowercased()
                let isSignatureFailure = message.contains("signature verification failed") || message.contains("unauthorized")
                guard hasNextMode, isSignatureFailure else {
                    throw error
                }
            }
        }
        if let lastError { throw lastError }
        throw KasiaError.apiError("KNS image upload failed")
    }
}
