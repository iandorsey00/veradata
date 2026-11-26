import Foundation

public enum VeraText {
    private static let bundle = Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj") != nil ? Bundle.main : Bundle.module

    private static let chinese = bundle.url(forResource: "zh-Hans", withExtension: "lproj").flatMap(Bundle.init(url:))

    public static func text(_ key: String, language: String? = nil) -> String {
        let preferred = language ?? Bundle.main.preferredLocalizations.first ?? "en"
        guard preferred == "zh-Hans" || preferred == "zh" || preferred.hasPrefix("zh-Hans-"),
              let chinese else { return key }
        return chinese.localizedString(forKey: key, value: key, table: nil)
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }
}
