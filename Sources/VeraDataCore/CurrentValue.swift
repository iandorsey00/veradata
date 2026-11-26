import Foundation

public enum CurrentValue: String, CaseIterable, Sendable {
    case today, timestamp

    public var title: String {
        switch self {
        case .today: return "Today’s date"
        case .timestamp: return "Current timestamp"
        }
    }

    private var terms: [String] {
        switch self {
        case .today: return ["today", "today s date", "today date", "todays date", "current date", "今天", "今天日期"]
        case .timestamp: return ["timestamp", "current timestamp", "now", "current time", "时间戳", "当前时间"]
        }
    }

    func match(_ query: String) -> Int? {
        if terms.contains(query) { return 130 }
        if query.count >= 3, terms.contains(where: { $0.hasPrefix(query) }) { return 82 }
        return nil
    }

    public func representations(
        at date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> [Representation] {
        switch self {
        case .today:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            let iso = formatter.string(from: date)

            let local = DateFormatter()
            local.locale = locale
            local.timeZone = timeZone
            local.dateStyle = .long
            return [
                Representation(label: "ISO date", text: iso),
                Representation(label: "Localized date", text: local.string(from: date)),
            ]
        case .timestamp:
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = timeZone
            let local = formatter.string(from: date)
            formatter.timeZone = TimeZone.gmt
            return [
                Representation(label: "Local with offset", text: local),
                Representation(label: "UTC", text: formatter.string(from: date)),
                Representation(label: "Unix seconds", text: String(Int64(date.timeIntervalSince1970.rounded(.down)))),
            ]
        }
    }
}

public struct AddressCoordinates: Equatable, Sendable {
    public static let fieldKeys = ["latitude", "longitude"]
    public let latitude: String
    public let longitude: String

    public init?(fields: [String: JSONValue]) {
        guard let latitude = Self.coordinate(fields["latitude"], limit: 90),
              let longitude = Self.coordinate(fields["longitude"], limit: 180) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    public var decimalDegrees: String { "\(latitude), \(longitude)" }

    private static func coordinate(_ value: JSONValue?, limit: Int) -> String? {
        guard let text = value?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines),
              let match = text.wholeMatch(of: #/([+-]?)([0-9]+)(\.[0-9]+)?/#) else { return nil }
        let digits = match.2.drop(while: { $0 == "0" })
        let integer = digits.isEmpty ? "0" : String(digits)
        let rest = match.3.map(String.init) ?? ""
        guard let degrees = Int(integer), degrees <= limit,
              degrees < limit || !rest.dropFirst().contains(where: { $0 != "0" })
        else { return nil }
        return (match.1 == "-" ? "-" : "") + integer + rest
    }
}
