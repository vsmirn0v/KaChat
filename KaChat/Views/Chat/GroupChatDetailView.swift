import SwiftUI
import PhotosUI

/// Group chat thread view - mirrors 1:1 chat's look (avatars, "+" send-mode menu, photo/audio
/// bubbles via the same `MediaFile`/`LazyImageBubble`/`LazyAudioBubble` components
/// `MessageBubbleView.swift` uses) with two deliberate differences: no in-thread payments (the
/// group protocol has no shared-wallet/escrow concept, same reason broadcast rooms don't support
/// them - "Pay in Kaspa" isn't in the "+" menu here), and audio recording reuses
/// `BroadcastAudioRecorder`'s simpler engine (broadcast already proved out group-shaped media
/// without 1:1's payment-integrated fee-estimation machinery).
struct GroupChatDetailView: View {
    let group: GroupChat
    var onDeleted: (() -> Void)? = nil
    @EnvironmentObject var groupChatService: GroupChatService
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var draft = ""
    @State private var showInfo = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @FocusState private var isComposerFocused: Bool
    @Environment(\.dismiss) private var dismiss

    // Avatar menu destinations - "View Profile"/"Open Chat"/"Pay in Kaspa" for a tapped member,
    // matching BroadcastChannelView's identical avatarButton pattern.
    @State private var openContact: Contact?
    @State private var openContactInPaymentMode = false
    @State private var profileContact: Contact?

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var pendingPhotoImage: UIImage?
    @State private var isSendingPhoto = false
    @StateObject private var recorder = BroadcastAudioRecorder()

    // Live "fee: N KAS" preview above the composer - matches 1:1/broadcast's identical bubble.
    @State private var feeEstimateSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var feeEstimateTask: Task<Void, Never>?
    @State private var feeShimmerPhase: CGFloat = -1

    /// Smaller than 1:1's `ImagePrep.defaultChatTargetBytes` (15,000) - group's `gcomm` payload
    /// hex-encodes the whole ciphertext (vs. 1:1's base64) plus fixed per-message overhead
    /// (blinded_group_id/sender_id/sender_pub/msg_id/signature, all hex), so the same raw photo
    /// size lands as a noticeably larger on-chain payload/fee in a group message.
    private static let groupPhotoTargetBytes = 10_000

    private var myAddress: String? { walletManager.currentWallet?.publicAddress }

    private var messages: [GroupMessage] {
        (groupChatService.groupMessages[group.id] ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { message in
                            GroupMessageBubbleRow(
                                message: message,
                                group: group,
                                avatarURLString: message.senderAddress.flatMap { knsService.profileCache[$0]?.avatarURL },
                                onCopy: showToast,
                                onViewProfile: viewProfile,
                                onOpenChat: { openChat(with: $0) },
                                onPayInKaspa: { openChat(with: $0, paymentMode: true) },
                                onCopyAddress: copyAddress,
                                onRetry: { retry(message) }
                            )
                            .id(message.id)
                            .task(id: message.senderAddress) {
                                guard let address = message.senderAddress, address != myAddress,
                                      knsService.profileCache[address] == nil else { return }
                                _ = await knsService.fetchProfile(for: address)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            composeBar
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            GroupChatInfoView(group: group, onDeleted: {
                dismiss()
                onDeleted?()
            })
        }
        .navigationDestination(isPresented: Binding(
            get: { openContact != nil },
            set: { if !$0 { openContact = nil } }
        )) {
            if let openContact {
                ChatDetailView(contact: openContact, startInPaymentMode: openContactInPaymentMode)
            } else {
                EmptyView()
            }
        }
        .sheet(isPresented: Binding(
            get: { profileContact != nil },
            set: { if !$0 { profileContact = nil } }
        )) {
            if let contact = profileContact {
                NavigationStack {
                    ChatInfoView(
                        contact: Binding(
                            get: { profileContact ?? contact },
                            set: { profileContact = $0 }
                        ),
                        title: "User Info",
                        showsNotificationSettings: false
                    )
                }
            }
        }
        .task {
            groupChatService.loadMessages(for: group.id)
            if let myAddress, knsService.profileCache[myAddress] == nil {
                _ = await knsService.fetchProfile(for: myAddress)
            }
        }
        .onChange(of: recorder.state) { state in
            if case .failed(let message) = state {
                errorMessage = message
            }
        }
        .toast(message: toastMessage, style: .success)
    }

    // MARK: - Compose bar

    private var composeBar: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let pendingPhotoImage {
                    photoPreviewRow(pendingPhotoImage)
                } else if recorder.state == .recording || recorder.state == .encoding {
                    recordingRow
                } else {
                    textRow
                }
            }

            if shouldShowFeeBubble {
                feeBubble
                    .offset(x: 32, y: -26)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: draft) { newValue in
            scheduleTextFeeEstimate(for: newValue)
        }
        .onChange(of: recorder.elapsedSeconds) { elapsed in
            updateRecordingFeeEstimate(elapsedSeconds: elapsed)
        }
    }

    // MARK: - Fee estimation

    private var shouldShowFeeBubble: Bool {
        if recorder.state == .recording || recorder.state == .encoding { return true }
        if pendingPhotoImage != nil { return true }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var feeBubble: some View {
        Group {
            if isEstimatingFee {
                Text("fee: -------- KAS")
            } else if let feeEstimateSompi {
                Text(localizedFeeText(feeEstimateSompi))
            } else {
                Text("fee: -- KAS")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(glassBackground(cornerRadius: 14))
        .overlay {
            if isEstimatingFee {
                FeeShimmerOverlay(phase: feeShimmerPhase)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            updateFeeShimmer()
        }
        .onChange(of: isEstimatingFee) { _ in
            updateFeeShimmer()
        }
    }

    private func localizedFeeText(_ feeSompi: UInt64) -> String {
        let template = NSLocalizedString("fee: %@ KAS", comment: "Fee label with resolved fee amount in KAS")
        return String(format: template, locale: Locale.current, formatKaspaExact(feeSompi))
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }

    private func updateFeeShimmer() {
        if isEstimatingFee {
            feeShimmerPhase = -1
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                feeShimmerPhase = 1
            }
        } else {
            feeShimmerPhase = -1
        }
    }

    private func scheduleTextFeeEstimate(for text: String) {
        feeEstimateTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }
        isEstimatingFee = true
        feeEstimateTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                let estimate = try await groupChatService.estimateGroupMessageFee(trimmed, for: group.id)
                guard !Task.isCancelled else { return }
                feeEstimateSompi = estimate
                isEstimatingFee = false
            } catch {
                guard !Task.isCancelled else { return }
                feeEstimateSompi = nil
                isEstimatingFee = false
            }
        }
    }

    private func schedulePhotoFeeEstimate() {
        feeEstimateTask?.cancel()
        isEstimatingFee = false
        feeEstimateSompi = groupChatService.estimateGroupMediaFee(rawBytes: Self.groupPhotoTargetBytes)
    }

    /// Raw encoded-Opus-bytes/sec estimate for `BroadcastAudioRecorder`'s fixed 6kbps/48kHz
    /// config (bitrate/8 + WebM container overhead) - matches `ChatDetailView.estimateEncodedSize`'s
    /// identical heuristic for the same recorder settings.
    private func updateRecordingFeeEstimate(elapsedSeconds: TimeInterval) {
        guard recorder.state == .recording else { return }
        let rawBytesPerSecond = 1_150.0
        let estimatedRawBytes = min(Int(elapsedSeconds * rawBytesPerSecond), 13_000)
        feeEstimateSompi = groupChatService.estimateGroupMediaFee(rawBytes: estimatedRawBytes)
        isEstimatingFee = false
    }

    private var textRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(glassBackground(cornerRadius: 20))

            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plusMenu
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    /// "+" menu - Photo and Audio Message only, deliberately no "Pay in Kaspa" (see file doc).
    private var plusMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
            Button {
                feeEstimateSompi = nil
                recorder.start()
            } label: {
                Label("Audio Message", systemImage: "mic.circle.fill")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(glassBackground(cornerRadius: 14))
        }
        .tint(.accentColor)
        .accessibilityLabel(Text("More options"))
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                defer { photoPickerItem = nil }
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    await MainActor.run { errorMessage = "Couldn't load that photo. Please try another." }
                    return
                }
                await MainActor.run {
                    isComposerFocused = false
                    pendingPhotoImage = image
                    schedulePhotoFeeEstimate()
                }
            }
        }
    }

    private func photoPreviewRow(_ image: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(isSendingPhoto ? "Sending photo…" : "Photo ready to send")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Button {
                pendingPhotoImage = nil
                feeEstimateSompi = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .disabled(isSendingPhoto)

            Button {
                sendPendingPhoto()
            } label: {
                if isSendingPhoto {
                    ProgressView()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.accentColor)
                }
            }
            .disabled(isSendingPhoto)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(glassBackground(cornerRadius: 20))
    }

    private var recordingRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    recorder.cancel()
                    feeEstimateSompi = nil
                } label: {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)

                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundColor(.red)

                Text(recorder.state == .encoding ? "Encoding…" : "Recording... \(Int(recorder.elapsedSeconds))s")
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(glassBackground(cornerRadius: 20))

            Button {
                sendRecording()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundColor(recorder.state == .encoding ? .secondary : .accentColor)
                    .frame(width: 36, height: 36)
                    .background(glassBackground(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(recorder.state == .encoding)
        }
        .onChange(of: recorder.elapsedSeconds) { elapsed in
            guard elapsed >= BroadcastAudioRecorder.maxDuration, recorder.state == .recording else { return }
            sendRecording()
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        errorMessage = nil
        Task {
            do {
                try await groupChatService.sendGroupMessage(text, to: group.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendPendingPhoto() {
        guard let pendingPhotoImage else { return }
        isSendingPhoto = true
        errorMessage = nil
        Task {
            do {
                let prepared = try ImagePrep.prepareForChatMessage(pendingPhotoImage, targetBytes: Self.groupPhotoTargetBytes)
                try await groupChatService.sendGroupImage(prepared.data, to: group.id, fileName: prepared.fileName, mimeType: prepared.mimeType)
                await MainActor.run {
                    self.pendingPhotoImage = nil
                    self.isSendingPhoto = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSendingPhoto = false
                }
            }
        }
    }

    private func sendRecording() {
        Task {
            do {
                let recorded = try await recorder.stopAndEncode()
                try await groupChatService.sendGroupAudio(recorded.data, to: group.id, fileName: recorded.fileName, mimeType: recorded.mimeType)
            } catch {
                await MainActor.run { errorMessage = "Failed to send voice message: \(error.localizedDescription)" }
            }
        }
    }

    private func openChat(with address: String, paymentMode: Bool = false) {
        guard address != myAddress else { return }
        let contact = contactsManager.getContact(byAddress: address)
            ?? contactsManager.getOrCreateContact(address: address)
        _ = chatService.getOrCreateConversation(for: contact)
        openContactInPaymentMode = paymentMode
        openContact = contact
    }

    private func viewProfile(_ address: String) {
        let contact = contactsManager.getContact(byAddress: address)
            ?? contactsManager.getOrCreateContact(address: address)
        profileContact = contact
    }

    private func copyAddress(_ address: String) {
        UIPasteboard.general.string = address
        showToast("Address copied.", style: .success)
    }

    /// Group messages don't have an in-place "retry" record the way 1:1 does - resends the same
    /// content (works uniformly for text/photo/audio, since all three are just a content string)
    /// as a fresh message rather than mutating the failed one, which stays in history marked failed.
    private func retry(_ message: GroupMessage) {
        errorMessage = nil
        Task {
            do {
                try await groupChatService.sendGroupMessage(message.content, to: group.id)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func showToast(_ message: String, style: ToastStyle) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

private struct GroupMessageBubbleRow: View {
    let message: GroupMessage
    let group: GroupChat
    let avatarURLString: String?
    let onCopy: (String, ToastStyle) -> Void
    let onViewProfile: (String) -> Void
    let onOpenChat: (String) -> Void
    let onPayInKaspa: (String) -> Void
    let onCopyAddress: (String) -> Void
    let onRetry: () -> Void

    @EnvironmentObject var settingsViewModel: SettingsViewModel

    private static let bubbleColor = Color(red: 112.0 / 255.0, green: 199.0 / 255.0, blue: 186.0 / 255.0)

    private var senderName: String {
        guard let address = message.senderAddress else { return "Unknown" }
        if let member = group.members.first(where: { $0.address == address }), let displayName = member.displayName, !displayName.isEmpty {
            return displayName
        }
        return String(address.suffix(10))
    }

    private var shouldShowRetry: Bool {
        message.isOutgoing && message.deliveryStatus == .failed
    }

    /// Parsed once per row - `nil` for a plain-text message, matching 1:1 chat's content-shape
    /// sniffing (`MediaFile.from`) rather than a stored message-type field.
    private var media: MediaFile? {
        MediaFile.from(message.content, cacheKey: message.txId)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !message.isOutgoing {
                avatarButton
            } else {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing {
                    Text(senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 4)
                }

                if let media, media.isImage {
                    LazyImageBubble(
                        media: media,
                        txId: message.txId,
                        shouldShowRetry: shouldShowRetry,
                        photosBlocked: false,
                        senderDisplayName: senderName,
                        onCopy: onCopy,
                        onRetry: shouldShowRetry ? { onRetry() } : nil,
                        onReply: nil
                    )
                } else if let media, media.isAudio, let data = media.fileData(cacheKey: message.txId) {
                    LazyAudioBubble(
                        data: data,
                        mimeType: media.mimeType,
                        isOutgoing: message.isOutgoing,
                        fileName: media.name,
                        txId: message.txId,
                        onCopy: onCopy,
                        onRetry: shouldShowRetry ? { onRetry() } : nil,
                        onReply: nil
                    )
                } else {
                    Text(message.content)
                        .font(.body)
                        .foregroundColor(message.isOutgoing ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.isOutgoing ? Self.bubbleColor : Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .contextMenu {
                            Button {
                                onCopy(message.content, .success)
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("Copy Message", systemImage: "doc.on.doc")
                            }
                            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: message.txId) {
                                Link(destination: url) {
                                    Label("View in Explorer", systemImage: "safari")
                                }
                            }
                            if shouldShowRetry {
                                Button {
                                    onRetry()
                                } label: {
                                    Label("Retry Send", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                        .tint(.accentColor)
                }

                if message.isOutgoing {
                    statusIcon
                }
            }

            if !message.isOutgoing { Spacer(minLength: 40) }
        }
    }

    /// Avatar with the same View Profile / Open Chat / Pay in Kaspa / Copy Address menu
    /// `BroadcastChannelView`'s `avatarButton` offers for a tapped sender.
    private var avatarButton: some View {
        Menu {
            if let address = message.senderAddress {
                Button {
                    onViewProfile(address)
                } label: {
                    Label("View Profile", systemImage: "person.crop.circle")
                }
                Button {
                    onOpenChat(address)
                } label: {
                    Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
                }
                Button {
                    onPayInKaspa(address)
                } label: {
                    Label {
                        Text("Pay in Kaspa")
                    } icon: {
                        Image("KaspaLogo")
                            .resizable()
                            .scaledToFit()
                    }
                }
                Button {
                    onCopyAddress(address)
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
            }
        } label: {
            KNSAvatarView(avatarURLString: avatarURLString, fallbackText: senderName, size: 32)
        }
        .tint(.accentColor)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.deliveryStatus {
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        case .warning:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }
}

/// Group membership. Kept intentionally minimal - member add/remove is a natural next step once
/// this is in front of you. No invite-link/join flow - every member is added directly by the
/// admin (see `GroupChatService`'s file doc for why the invite beacon was removed).
struct GroupChatInfoView: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var knsService = KNSService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var profileContact: Contact?
    var onDeleted: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section("Members (\(group.members.count))") {
                    ForEach(group.members) { member in
                        let hasDisplayName = !(member.displayName ?? "").isEmpty
                        let memberLabel = hasDisplayName ? (member.displayName ?? "") : String(member.address.suffix(10))
                        Button {
                            profileContact = contactsManager.getContact(byAddress: member.address)
                                ?? contactsManager.getOrCreateContact(address: member.address)
                        } label: {
                            HStack(spacing: 12) {
                                KNSAvatarView(avatarURLString: knsService.profileCache[member.address]?.avatarURL, fallbackText: memberLabel, size: 32)
                                Text(memberLabel)
                                    .font(.system(.body, design: hasDisplayName ? .default : .monospaced))
                                    .foregroundColor(.primary)
                                Spacer()
                                if member.isAdmin {
                                    Text("Admin")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .task {
                            guard knsService.profileCache[member.address] == nil else { return }
                            _ = await knsService.fetchProfile(for: member.address)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Group", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: Binding(
                get: { profileContact != nil },
                set: { if !$0 { profileContact = nil } }
            )) {
                if let contact = profileContact {
                    NavigationStack {
                        ChatInfoView(
                            contact: Binding(
                                get: { profileContact ?? contact },
                                set: { profileContact = $0 }
                            ),
                            title: "User Info",
                            showsNotificationSettings: false
                        )
                    }
                }
            }
            .alert("Delete \"\(group.name)\"", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    groupChatService.deleteGroup(group.id)
                    dismiss()
                    onDeleted?()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the group and its messages from this device. This cannot be undone, and other members won't be notified.")
            }
        }
    }
}
