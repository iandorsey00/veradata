import Foundation

public enum VeraText {
    private static let bundle: Bundle = {
        if Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                           subdirectory: nil, localization: "zh-Hans") != nil { return .main }
        // The installed CLI runs from Contents/Helpers, while its translations live in the app's Resources folder.
        if let helpers = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent(),
           helpers.lastPathComponent == "Helpers" {
            let contents = helpers.deletingLastPathComponent()
            let app = contents.deletingLastPathComponent()
            if contents.lastPathComponent == "Contents", app.pathExtension == "app",
               let bundle = Bundle(url: app), bundle.url(forResource: "zh-Hans", withExtension: "lproj") != nil {
                return bundle
            }
        }
        return .module
    }()

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
