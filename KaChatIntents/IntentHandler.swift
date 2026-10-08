import Intents

/// The Intents extension behind "Call with KaChat" in the Contacts app, Siri ("call Alice on
/// KaChat") and the phone's Recents. It only resolves WHO is being called against the
/// contacts the app shares through the App Group and hands the call to the app to place -
/// the extension never touches Nextcloud, the chain, or the wallet.
final class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        if intent is INStartCallIntent {
            return StartCallIntentHandler()
        }
        return self
    }
}

final class StartCallIntentHandler: NSObject, INStartCallIntentHandling {
    /// What the app wrote for us: every contact with calls enabled, by KaChat address and name
    /// (`SharedDataManager.syncCallContactsForIntents`). KaChat doesn't use the phone's Contacts.
    private struct CallContact: Decodable {
        let address: String
        let name: String
    }

    private static let appGroupIdentifier = "group.com.kachat.app"
    private static let key = "call_contacts"

    private func callContacts() -> [CallContact] {
        guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier),
              let data = defaults.data(forKey: Self.key),
              let contacts = try? JSONDecoder().decode([CallContact].self, from: data) else {
            return []
        }
        return contacts
    }

    private func person(for contact: CallContact) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: contact.address, type: .unknown),
            nameComponents: nil,
            displayName: contact.name,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: contact.address
        )
    }

    /// Siri names a person by a spoken name; a Recents entry or our own donation by the KaChat
    /// address in `customIdentifier`.
    private func matches(_ person: INPerson, in contacts: [CallContact]) -> [CallContact] {
        if let custom = person.customIdentifier, !custom.isEmpty,
           let exact = contacts.first(where: { $0.address == custom }) {
            return [exact]
        }
        if let value = person.personHandle?.value, !value.isEmpty,
           let exact = contacts.first(where: { $0.address == value }) {
            return [exact]
        }
        let spoken = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !spoken.isEmpty else { return [] }
        let exact = contacts.filter { $0.name.lowercased() == spoken }
        if !exact.isEmpty { return exact }
        return contacts.filter { $0.name.lowercased().contains(spoken) || spoken.contains($0.name.lowercased()) }
    }

    func resolveContacts(for intent: INStartCallIntent, with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        let contacts = callContacts()
        guard let requested = intent.contacts, !requested.isEmpty else {
            completion([.needsValue()])
            return
        }
        let results: [INStartCallContactResolutionResult] = requested.map { person in
            let found = matches(person, in: contacts)
            switch found.count {
            case 0:
                return .unsupported(forReason: .noContactFound)
            case 1:
                return .success(with: self.person(for: found[0]))
            default:
                return .disambiguation(with: found.map { self.person(for: $0) })
            }
        }
        completion(results)
    }

    func resolveCallCapability(for intent: INStartCallIntent, with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void) {
        switch intent.callCapability {
        case .videoCall:
            completion(.success(with: .videoCall))
        default:
            completion(.success(with: .audioCall))
        }
    }

    func resolveDestinationType(for intent: INStartCallIntent, with completion: @escaping (INCallDestinationTypeResolutionResult) -> Void) {
        completion(.success(with: .normal))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        // The extension cannot ring anyone; the app continues with exactly whom to call and how.
        let activity = NSUserActivity(activityType: NSStringFromClass(INStartCallIntent.self))
        var info: [String: Any] = ["video": intent.callCapability == .videoCall]
        if let address = intent.contacts?.first?.customIdentifier ?? intent.contacts?.first?.personHandle?.value {
            info["address"] = address
        }
        activity.userInfo = info
        completion(INStartCallIntentResponse(code: .continueInApp, userActivity: activity))
    }
}
