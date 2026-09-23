import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case english = "en"

    static let defaultsKey = "locus.appLanguage"
    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System Default")
        case .zhHans: return "简体中文"
        case .english: return "English"
        }
    }
}
