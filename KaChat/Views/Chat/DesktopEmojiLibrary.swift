import Foundation

enum DesktopEmojiCategory: String, CaseIterable, Identifiable {
    case smileys
    case people
    case nature
    case food
    case travel
    case activities
    case objects
    case symbols
    case flags

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smileys: return "face.smiling"
        case .people: return "person.2"
        case .nature: return "leaf"
        case .food: return "fork.knife"
        case .travel: return "car"
        case .activities: return "soccerball"
        case .objects: return "lightbulb"
        case .symbols: return "heart"
        case .flags: return "flag"
        }
    }

    var title: String {
        switch self {
        case .smileys: return "Smileys"
        case .people: return "People"
        case .nature: return "Nature"
        case .food: return "Food"
        case .travel: return "Travel"
        case .activities: return "Activities"
        case .objects: return "Objects"
        case .symbols: return "Symbols"
        case .flags: return "Flags"
        }
    }
}

struct DesktopEmojiItem: Identifiable, Hashable {
    let emoji: String
    let category: DesktopEmojiCategory
    let keywords: String

    var id: String { emoji }
}

enum DesktopEmojiLibrary {
    static let items: [DesktopEmojiItem] = makeItems()
    static let allEmoji: [String] = items.map(\.emoji)

    static func emoji(in category: DesktopEmojiCategory) -> [DesktopEmojiItem] {
        items.filter { $0.category == category }
    }

    static func search(_ query: String) -> [String] {
        searchItems(query).map(\.emoji)
    }

    static func searchItems(_ query: String) -> [DesktopEmojiItem] {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return items }

        return items.filter { item in
            let searchableText = "\(item.emoji) \(item.keywords)"
            return tokens.allSatisfy { searchableText.contains($0) }
        }
    }

    private static func makeItems() -> [DesktopEmojiItem] {
        var seen = Set<String>()
        var output: [DesktopEmojiItem] = []

        func append(_ emoji: String, category: DesktopEmojiCategory, keywords: String) {
            guard seen.insert(emoji).inserted else { return }
            output.append(DesktopEmojiItem(emoji: emoji, category: category, keywords: keywords.lowercased()))
        }

        let scalarItems = makeScalarEmojiItems()
        for item in scalarItems {
            append(item.emoji, category: item.category, keywords: item.keywords)
        }

        for item in scalarItems where item.isEmojiModifierBase {
            for tone in skinToneModifiers {
                append(
                    String(item.scalar) + tone.emoji,
                    category: .people,
                    keywords: "\(item.keywords) \(tone.keywords)"
                )
            }
        }

        for sequence in commonSequences {
            append(sequence.emoji, category: sequence.category, keywords: sequence.keywords)
        }

        for flag in makeRegionFlags() {
            append(flag.emoji, category: .flags, keywords: flag.keywords)
        }

        return output
    }

    private struct ScalarEmojiItem {
        let emoji: String
        let scalar: Unicode.Scalar
        let category: DesktopEmojiCategory
        let keywords: String

        var isEmojiModifierBase: Bool {
            scalar.properties.isEmojiModifierBase
        }
    }

    private static func makeScalarEmojiItems() -> [ScalarEmojiItem] {
        let variationSelector = "\u{FE0F}"
        var output: [ScalarEmojiItem] = []

        for value in emojiScalarValues {
            guard let scalar = Unicode.Scalar(value), shouldInclude(scalar) else { continue }
            let properties = scalar.properties
            let emoji = properties.isEmojiPresentation ? String(scalar) : String(scalar) + variationSelector
            let keywords = "\(properties.name?.lowercased() ?? "") \(category(for: scalar).title.lowercased())"
            output.append(
                ScalarEmojiItem(
                    emoji: emoji,
                    scalar: scalar,
                    category: category(for: scalar),
                    keywords: keywords
                )
            )
        }

        return output
    }

    private static var emojiScalarValues: [UInt32] {
        let ranges: [ClosedRange<UInt32>] = [
            0x00A9...0x00AE,
            0x203C...0x3299,
            0x1F000...0x1FAFF
        ]
        return ranges.flatMap { Array($0) }
    }

    private static func shouldInclude(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        guard properties.isEmojiPresentation || properties.isEmoji else { return false }

        switch scalar.value {
        case 0x0023, 0x002A, 0x0030...0x0039:
            return false
        case 0x1F1E6...0x1F1FF, 0x1F3FB...0x1F3FF:
            return false
        default:
            return true
        }
    }

    private static func category(for scalar: Unicode.Scalar) -> DesktopEmojiCategory {
        switch scalar.value {
        case 0x1F600...0x1F64F, 0x1F970...0x1F97F:
            return .smileys
        case 0x1F300...0x1F32C, 0x1F330...0x1F335, 0x1F337...0x1F343, 0x1F400...0x1F43F, 0x1F980...0x1F9AE:
            return .nature
        case 0x1F32D...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB:
            return .food
        case 0x1F680...0x1F6FF, 0x1F3E0...0x1F3F0:
            return .travel
        case 0x1F380...0x1F3DF, 0x1F3F8...0x1F3FF, 0x1F93C...0x1F945:
            return .activities
        case 0x1F466...0x1F487, 0x1F590...0x1F596, 0x1F645...0x1F64F, 0x1F900...0x1F93B, 0x1F9B0...0x1F9DF:
            return .people
        case 0x1F4A0...0x1F5FF, 0x1F9E0...0x1FAFF:
            return .objects
        default:
            return .symbols
        }
    }

    private struct ExtraSequence {
        let emoji: String
        let category: DesktopEmojiCategory
        let keywords: String
    }

    private static let skinToneModifiers: [ExtraSequence] = [
        ExtraSequence(emoji: "\u{1F3FB}", category: .people, keywords: "light skin tone"),
        ExtraSequence(emoji: "\u{1F3FC}", category: .people, keywords: "medium light skin tone"),
        ExtraSequence(emoji: "\u{1F3FD}", category: .people, keywords: "medium skin tone"),
        ExtraSequence(emoji: "\u{1F3FE}", category: .people, keywords: "medium dark skin tone"),
        ExtraSequence(emoji: "\u{1F3FF}", category: .people, keywords: "dark skin tone")
    ]

    private static let commonSequences: [ExtraSequence] = [
        ExtraSequence(emoji: "❤️", category: .symbols, keywords: "red heart love"),
        ExtraSequence(emoji: "❤️‍🔥", category: .symbols, keywords: "heart on fire love"),
        ExtraSequence(emoji: "❤️‍🩹", category: .symbols, keywords: "mending heart heal love"),
        ExtraSequence(emoji: "🏳️‍🌈", category: .flags, keywords: "rainbow pride flag"),
        ExtraSequence(emoji: "🏳️‍⚧️", category: .flags, keywords: "transgender pride flag"),
        ExtraSequence(emoji: "🏴‍☠️", category: .flags, keywords: "pirate flag"),
        ExtraSequence(emoji: "👁️‍🗨️", category: .symbols, keywords: "eye speech bubble witness"),
        ExtraSequence(emoji: "😶‍🌫️", category: .smileys, keywords: "face in clouds fog"),
        ExtraSequence(emoji: "😮‍💨", category: .smileys, keywords: "face exhaling relief"),
        ExtraSequence(emoji: "😵‍💫", category: .smileys, keywords: "face dizzy spiral eyes"),
        ExtraSequence(emoji: "🙂‍↕️", category: .smileys, keywords: "head nod yes"),
        ExtraSequence(emoji: "🙂‍↔️", category: .smileys, keywords: "head shake no"),
        ExtraSequence(emoji: "🐈‍⬛", category: .nature, keywords: "black cat"),
        ExtraSequence(emoji: "🐻‍❄️", category: .nature, keywords: "polar bear"),
        ExtraSequence(emoji: "🐦‍🔥", category: .nature, keywords: "phoenix bird fire"),
        ExtraSequence(emoji: "👨‍💻", category: .people, keywords: "man technologist coder developer"),
        ExtraSequence(emoji: "👩‍💻", category: .people, keywords: "woman technologist coder developer"),
        ExtraSequence(emoji: "🧑‍💻", category: .people, keywords: "person technologist coder developer"),
        ExtraSequence(emoji: "👨‍🚀", category: .people, keywords: "man astronaut"),
        ExtraSequence(emoji: "👩‍🚀", category: .people, keywords: "woman astronaut"),
        ExtraSequence(emoji: "🧑‍🚀", category: .people, keywords: "person astronaut"),
        ExtraSequence(emoji: "👨‍⚕️", category: .people, keywords: "man health worker doctor"),
        ExtraSequence(emoji: "👩‍⚕️", category: .people, keywords: "woman health worker doctor"),
        ExtraSequence(emoji: "🧑‍⚕️", category: .people, keywords: "person health worker doctor"),
        ExtraSequence(emoji: "👨‍🏫", category: .people, keywords: "man teacher"),
        ExtraSequence(emoji: "👩‍🏫", category: .people, keywords: "woman teacher"),
        ExtraSequence(emoji: "🧑‍🏫", category: .people, keywords: "person teacher"),
        ExtraSequence(emoji: "👨‍🍳", category: .people, keywords: "man cook chef"),
        ExtraSequence(emoji: "👩‍🍳", category: .people, keywords: "woman cook chef"),
        ExtraSequence(emoji: "🧑‍🍳", category: .people, keywords: "person cook chef"),
        ExtraSequence(emoji: "👨‍👩‍👧", category: .people, keywords: "family"),
        ExtraSequence(emoji: "👨‍👩‍👦", category: .people, keywords: "family"),
        ExtraSequence(emoji: "👩‍👩‍👧", category: .people, keywords: "family"),
        ExtraSequence(emoji: "👨‍👨‍👦", category: .people, keywords: "family"),
        ExtraSequence(emoji: "👩‍👧", category: .people, keywords: "family mother daughter"),
        ExtraSequence(emoji: "👨‍👦", category: .people, keywords: "family father son")
    ]

    private static func makeRegionFlags() -> [ExtraSequence] {
        Locale.Region.isoRegions.compactMap { region -> ExtraSequence? in
            let code = region.identifier
            guard code.count == 2 else { return nil }
            let scalars = code.uppercased().unicodeScalars
            guard scalars.allSatisfy({ ("A"..."Z").contains(String($0)) }) else { return nil }
            let flag = scalars.compactMap { scalar -> Unicode.Scalar? in
                Unicode.Scalar(0x1F1E6 + scalar.value - Unicode.Scalar("A").value)
            }.map(String.init).joined()
            let regionName = Locale.current.localizedString(forRegionCode: code) ?? code
            return ExtraSequence(emoji: flag, category: .flags, keywords: "flag \(code.lowercased()) \(regionName.lowercased())")
        }
    }
}
