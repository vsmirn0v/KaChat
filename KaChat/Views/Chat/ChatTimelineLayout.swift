import Foundation

enum ChatTimelineItem: Equatable, Identifiable {
    case daySeparator(Date)
    case message(index: Int, ChatMessage)

    var id: String {
        switch self {
        case .daySeparator(let day):
            return "day-\(Int(day.timeIntervalSince1970))"
        case .message(_, let message):
            return "message-\(message.id.uuidString)"
        }
    }
}

enum ChatTimelineLayout {
    static func items(
        for messages: [ChatMessage],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ChatTimelineItem] {
        var items: [ChatTimelineItem] = []
        var previousDay: Date?

        for (index, message) in messages.enumerated() {
            let messageDay = calendar.startOfDay(for: message.timestamp)
            if previousDay.map({ calendar.isDate($0, inSameDayAs: messageDay) }) != true {
                items.append(.daySeparator(messageDay))
                previousDay = messageDay
            }
            items.append(.message(index: index, message))
        }

        return items
    }
}

enum MessageDaySeparatorFormatter {
    static func label(
        for date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar inputCalendar: Calendar = .autoupdatingCurrent,
        locale: Locale = preferredLocale
    ) -> String {
        var calendar = inputCalendar
        calendar.locale = locale

        let day = calendar.startOfDay(for: date)
        let referenceDay = calendar.startOfDay(for: referenceDate)
        if calendar.isDate(day, inSameDayAs: referenceDay)
            || calendar.isDate(day, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: referenceDay) ?? referenceDay) {
            return relativeFormatter(calendar: calendar, locale: locale).string(from: day)
        }

        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: referenceDay)
        let template = sameYear ? "EEEE, MMM d" : "MMM d, y"
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: day)
    }

    static func isToday(
        _ date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar inputCalendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        var calendar = inputCalendar
        calendar.locale = .autoupdatingCurrent
        return calendar.isDate(date, inSameDayAs: referenceDate)
    }

    /// Checks the in-app selected language (see `AppLocalization`) before falling back to the
    /// device's own preferred-localization resolution, so day-separator labels ("Today",
    /// month/weekday names) follow an in-app language switch immediately too, not just `Text`.
    private static var preferredLocale: Locale {
        if let appLocale = AppSettings.load().language.locale {
            return appLocale
        }
        if let localization = Bundle.main.preferredLocalizations.first,
           localization != "Base" {
            return Locale(identifier: localization)
        }
        if let language = Locale.preferredLanguages.first {
            return Locale(identifier: language)
        }
        return .autoupdatingCurrent
    }

    private static func relativeFormatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }
}
