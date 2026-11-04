import Foundation

public enum AppPreferences {
    // Keep the original key so promoting the feature preserves saved on/off choices.
    public static let animatedCatKey = "showExperimentalCat"

    public static func animatedCatEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: animatedCatKey) as? Bool ?? true
    }

    // Older Homebrew installs stored preferences under the raw executable's name.
    // Only fill missing values; a saved false in the canonical suite must win.
    public static func migrateLegacyValues(from legacy: UserDefaults?, to defaults: UserDefaults) {
        for key in ["period", "periodRangeStyle", "showGraph", "showProviderIcons",
                    "showFullModelNames", "menuBarFields", "theme", animatedCatKey,
                    "showExperimentalAttribution"]
            where defaults.object(forKey: key) == nil {
            if let value = legacy?.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }
}
