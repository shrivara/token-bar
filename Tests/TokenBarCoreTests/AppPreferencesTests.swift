import XCTest
@testable import TokenBarCore

final class AppPreferencesTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "com.shrivara.tokenbar.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    func testAnimatedCatIsEnabledWhenPreferenceIsUnset() throws {
        let defaults = try makeDefaults()

        XCTAssertTrue(AppPreferences.animatedCatEnabled(in: defaults))
        XCTAssertNil(defaults.object(forKey: "showExperimentalCat"))
    }

    func testExistingAnimatedCatChoicesArePreserved() throws {
        for enabled in [false, true] {
            let defaults = try makeDefaults()
            defaults.set(enabled, forKey: "showExperimentalCat")

            XCTAssertEqual(AppPreferences.animatedCatEnabled(in: defaults), enabled)
            XCTAssertEqual(defaults.object(forKey: "showExperimentalCat") as? Bool, enabled)
        }
    }

    func testMissingLegacyPreferencesKeepTheEnabledDefault() throws {
        let defaults = try makeDefaults()
        AppPreferences.migrateLegacyValues(from: nil, to: defaults)
        AppPreferences.migrateLegacyValues(from: try makeDefaults(), to: defaults)

        XCTAssertTrue(AppPreferences.animatedCatEnabled(in: defaults))
        XCTAssertNil(defaults.object(forKey: "showExperimentalCat"))
    }

    func testLegacyAnimatedCatChoicesAreMigrated() throws {
        for enabled in [false, true] {
            let defaults = try makeDefaults()
            let legacy = try makeDefaults()
            legacy.set(enabled, forKey: "showExperimentalCat")

            AppPreferences.migrateLegacyValues(from: legacy, to: defaults)

            XCTAssertEqual(defaults.object(forKey: "showExperimentalCat") as? Bool, enabled)
            XCTAssertEqual(AppPreferences.animatedCatEnabled(in: defaults), enabled)
            XCTAssertEqual(legacy.object(forKey: "showExperimentalCat") as? Bool, enabled)
        }
    }

    func testCanonicalAnimatedCatChoiceWinsOverLegacyChoice() throws {
        for enabled in [false, true] {
            let defaults = try makeDefaults()
            let legacy = try makeDefaults()
            defaults.set(enabled, forKey: "showExperimentalCat")
            legacy.set(!enabled, forKey: "showExperimentalCat")

            AppPreferences.migrateLegacyValues(from: legacy, to: defaults)

            XCTAssertEqual(AppPreferences.animatedCatEnabled(in: defaults), enabled)
        }
    }

    func testDisablingTheCatSurvivesRepeatedMigration() throws {
        let defaults = try makeDefaults()
        let legacy = try makeDefaults()
        legacy.set(true, forKey: "showExperimentalCat")
        AppPreferences.migrateLegacyValues(from: legacy, to: defaults)
        XCTAssertTrue(AppPreferences.animatedCatEnabled(in: defaults))

        defaults.set(false, forKey: AppPreferences.animatedCatKey)
        AppPreferences.migrateLegacyValues(from: legacy, to: defaults)

        XCTAssertFalse(AppPreferences.animatedCatEnabled(in: defaults))
        XCTAssertEqual(defaults.object(forKey: "showExperimentalCat") as? Bool, false)
    }

    func testOtherLegacyViewPreferencesStillMigrateWithoutOverwritingChoices() throws {
        let defaults = try makeDefaults()
        let legacy = try makeDefaults()
        legacy.set(false, forKey: "showGraph")
        legacy.set(true, forKey: "showExperimentalAttribution")
        legacy.set("dracula", forKey: "theme")
        defaults.set("nord", forKey: "theme")

        AppPreferences.migrateLegacyValues(from: legacy, to: defaults)

        XCTAssertEqual(defaults.object(forKey: "showGraph") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "showExperimentalAttribution") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "theme"), "nord")
    }
}
