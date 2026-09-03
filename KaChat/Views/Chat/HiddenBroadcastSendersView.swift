import SwiftUI

/// Manage senders hidden in ONE broadcast room - reached from Room Info (tap the #name in the
/// room). A hidden user's messages never show in this room and never notify (local banners
/// and, for indexed channels, remote push via the registration's hidden map).
struct HiddenBroadcastSendersView: View {
    let channel: String

    @EnvironmentObject var broadcastService: BroadcastService
    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var knsService = KNSService.shared

    @State private var hiddenAddresses: [String] = []

    var body: some View {
        List {
            if hiddenAddresses.isEmpty {
                Text("No hidden users in #\(channel). Long-press a message to hide its sender.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(hiddenAddresses, id: \.self) { address in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(for: address))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(address)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Unhide") {
                            broadcastService.unhideSender(address, inChannel: channel)
                            reload()
                        }
                        .font(.caption)
                    }
                    .task(id: address) {
                        guard knsService.profileCache[address] == nil else { return }
                        _ = await knsService.fetchProfile(for: address)
                    }
                }
            }
        }
        .navigationTitle("Hidden Users - #\(channel)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reload()
        }
    }

    /// Same alias -> KNS name -> short address fallback used inside a broadcast room, so a
    /// hidden sender's name here reads identically to how it did before being hidden.
    private func displayName(for address: String) -> String {
        if let assigned = contactsManager.getContact(byAddress: address)?.assignedName {
            return assigned
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    private func reload() {
        hiddenAddresses = Array(broadcastService.hiddenSenderAddresses(forChannel: channel)).sorted()
    }
}

#Preview {
    NavigationStack {
        HiddenBroadcastSendersView(channel: "kaspa")
            .environmentObject(BroadcastService.shared)
            .environmentObject(ContactsManager.shared)
    }
}
