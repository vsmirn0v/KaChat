import AppIntents
import Foundation

@available(iOS 16.0, macCatalyst 16.0, *)
struct KaChatContactEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "KaChat Contact"
    static var defaultQuery = KaChatContactEntityQuery()

    let id: String
    let alias: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(alias)",
            subtitle: "\(id)"
        )
    }
}

@available(iOS 16.0, macCatalyst 16.0, *)
struct KaChatContactEntityQuery: EntityStringQuery {
    func entities(for identifiers: [KaChatContactEntity.ID]) async throws -> [KaChatContactEntity] {
        await MainActor.run {
            let contacts = ContactsManager.shared.contacts
            return identifiers.compactMap { identifier in
                guard let contact = contacts.first(where: { $0.address == identifier }) else {
                    return nil
                }
                return KaChatContactEntity(id: contact.address, alias: contact.alias)
            }
        }
    }

    func suggestedEntities() async throws -> [KaChatContactEntity] {
        await MainActor.run {
            ContactsManager.shared.activeContacts
                .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
                .map { KaChatContactEntity(id: $0.address, alias: $0.alias) }
        }
    }

    func entities(matching string: String) async throws -> [KaChatContactEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return try await suggestedEntities()
        }

        return await MainActor.run {
            ContactsManager.shared.searchContacts(query, includeArchived: true)
                .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
                .map { KaChatContactEntity(id: $0.address, alias: $0.alias) }
        }
    }
}
