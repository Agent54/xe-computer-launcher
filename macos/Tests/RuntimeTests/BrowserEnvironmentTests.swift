import Testing
import Foundation
@testable import macos

struct BrowserEnvironmentTests {
    @Test func environmentsWithTheSameEngineReuseTheBrowserProfile() {
        let released: [String: Any] = [
            "selected_profile": "default",
            "selected_chrome_variant": "helium"
        ]
        let development: [String: Any] = [
            "selected_profile": "dev",
            "selected_chrome_variant": "helium",
            "overrides": ["dev": ["darc": ["url": "https://localhost:5194"]]]
        ]
        #expect(ExternalState.browserProfileName(settings: released) == "default")
        #expect(ExternalState.browserProfileName(settings: development) ==
                ExternalState.browserProfileName(settings: released))
    }

    @Test func differentEnginesUseDifferentProfiles() {
        let profiles = ["helium", "stable", "beta", "canary"].map { variant in
            ExternalState.browserProfileName(settings: [
                "selected_profile": "dev", "selected_chrome_variant": variant
            ])
        }
        #expect(Set(profiles).count == profiles.count)
        #expect(ExternalState.browserProfileName(settings: [:]) == "default")
    }

    @Test func environmentChoicesComeFromConfiguration() {
        let settings: [String: Any] = [
            "selected_profile": "work",
            "environment_names": ["default", "dev", "work", "dev"],
            "overrides": ["preview": ["darc": ["url": "https://preview.localhost"]]]
        ]
        #expect(ExternalState.environmentNames(settings: settings) == ["default", "dev", "preview", "work"])
        #expect(ExternalState.environmentNames(settings: [:]) == ["default"])
    }

    @Test func shimsAreSharedByBrowserProfileAndIWASource() {
        let data = URL(fileURLWithPath: "/test/xe")
        let released = ExternalState.darcShimAppURL(dataURL: data, profileName: "default", overrideURL: nil)
        let dev = ExternalState.darcShimAppURL(dataURL: data, profileName: "default", overrideURL: "https://localhost:5194")
        let sameDev = ExternalState.darcShimAppURL(dataURL: data, profileName: "default", overrideURL: "https://localhost:5194")
        let otherDev = ExternalState.darcShimAppURL(dataURL: data, profileName: "default", overrideURL: "https://localhost:5195")
        let otherBrowser = ExternalState.darcShimAppURL(dataURL: data, profileName: "beta", overrideURL: "https://localhost:5194")
        #expect(released.path == "/test/xe/shims/default/Xe Computer.app")
        #expect(dev == sameDev)
        #expect(dev != released)
        #expect(dev != otherDev)
        #expect(dev != otherBrowser)
    }
}
