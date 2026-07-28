import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: return "Follow System"
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        }
    }

    var resolvedLanguageCode: String {
        switch self {
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .system:
            let preferred = Locale.preferredLanguages.first?
                .lowercased() ?? "en"
            return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        }
    }

    var locale: Locale {
        Locale(identifier: resolvedLanguageCode)
    }

    static var current: AppLanguage {
        let rawValue = UserDefaults.standard.string(
            forKey: storageKey
        ) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }
}

enum L10n {
    static func string(_ key: String) -> String {
        localizedBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key),
            locale: AppLanguage.current.locale,
            arguments: arguments
        )
    }

    private static var localizedBundle: Bundle {
        let code = AppLanguage.current.resolvedLanguageCode
        guard let path = Bundle.main.path(
            forResource: code,
            ofType: "lproj"
        ),
        let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}
