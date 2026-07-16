import Foundation

@main
struct ChatTimelineDaySeparatorsTest {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let reference = makeDate(year: 2026, month: 7, day: 7, hour: 12, calendar: calendar)
        let todayMorning = makeDate(year: 2026, month: 7, day: 7, hour: 9, calendar: calendar)
        let todayAfternoon = makeDate(year: 2026, month: 7, day: 7, hour: 15, calendar: calendar)
        let yesterday = makeDate(year: 2026, month: 7, day: 6, hour: 22, calendar: calendar)

        let messages = [
            message(id: "00000000-0000-0000-0000-000000000001", date: yesterday),
            message(id: "00000000-0000-0000-0000-000000000002", date: todayMorning),
            message(id: "00000000-0000-0000-0000-000000000003", date: todayAfternoon)
        ]
        let items = ChatTimelineLayout.items(for: messages, calendar: calendar)

        expect(items.count == 5, "expected one separator per day plus all messages")
        expect(isSeparator(items[0], day: yesterday, calendar: calendar), "first item should be yesterday separator")
        expect(isMessage(items[1], index: 0, id: messages[0].id), "second item should be yesterday message")
        expect(isSeparator(items[2], day: todayMorning, calendar: calendar), "third item should be today separator")
        expect(isMessage(items[3], index: 1, id: messages[1].id), "fourth item should be first today message")
        expect(isMessage(items[4], index: 2, id: messages[2].id), "fifth item should be second today message")

        let englishToday = MessageDaySeparatorFormatter.label(
            for: todayMorning,
            relativeTo: reference,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )
        expect(englishToday == "Today", "English today label should use relative localized date")

        let englishYesterday = MessageDaySeparatorFormatter.label(
            for: yesterday,
            relativeTo: reference,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )
        expect(englishYesterday == "Yesterday", "English yesterday label should use relative localized date")

        let russianToday = MessageDaySeparatorFormatter.label(
            for: todayMorning,
            relativeTo: reference,
            calendar: calendar,
            locale: Locale(identifier: "ru_RU")
        ).lowercased()
        expect(russianToday.contains("сегодня"), "Russian today label should be localized")

        print("PASS: ChatTimelineDaySeparators")
    }

    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    private static func message(id: String, date: Date) -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: id)!,
            txId: id,
            senderAddress: "kaspa:sender",
            receiverAddress: "kaspa:receiver",
            content: "Message",
            timestamp: date,
            blockTime: UInt64(date.timeIntervalSince1970),
            isOutgoing: false
        )
    }

    private static func isSeparator(_ item: ChatTimelineItem, day: Date, calendar: Calendar) -> Bool {
        guard case let .daySeparator(separatorDay) = item else { return false }
        return calendar.isDate(separatorDay, inSameDayAs: day)
    }

    private static func isMessage(_ item: ChatTimelineItem, index: Int, id: UUID) -> Bool {
        guard case let .message(messageIndex, message) = item else { return false }
        return messageIndex == index && message.id == id
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
