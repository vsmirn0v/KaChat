import SwiftUI

/// Manage senders hidden across broadcast channels for the current wallet.
/// Mirrors Android's `HiddenBroadcastUsersScreen`.
struct HiddenBroadcastSendersView: View {
    @EnvironmentObject var broadcastService: BroadcastService
    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var knsService = KNSService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var hiddenAddresses: [String] = []

    var body: some View {
        List {
            if hiddenAddresses.isEmpty {
                Text("No hidden senders")
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
                            broadcastService.unhideSender(address)
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
        .navigationTitle("Hidden Broadcast Room Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            reload()
        }
    }

    /// Same alias -> KNS name -> short address fallback used inside a broadcast room, so a
    /// hidden sender's name here reads identically to how it did before being hidden.
    private func displayName(for address: String) -> String {
        if let contact = contactsManager.getContact(byAddress: address), !contact.alias.isEmpty {
            return contact.alias
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return String(address.suffix(10))
    }

    private func reload() {
        hiddenAddresses = Array(broadcastService.hiddenSenderAddresses()).sorted()
    }
}

#Preview {
    NavigationStack {
        HiddenBroadcastSendersView()
            .environmentObject(BroadcastService.shared)
            .environmentObject(ContactsManager.shared)
    }
}
