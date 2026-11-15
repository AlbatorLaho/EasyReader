import Foundation
import Testing

@testable import EasyReader

/// Chromium detection by bundle layout, on fake app bundles in a temp folder.
struct AppAccessibilityTests {
    /// Makes `<name>.app` with a framework holding `helpers` in `Versions/Current/Helpers`.
    private func app(_ name: String, framework: String, helpers: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppAccessibilityTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("\(name).app")
        let helperFolder = app.appendingPathComponent("Contents/Frameworks/\(framework).framework/Versions/Current/Helpers")
        try FileManager.default.createDirectory(at: helperFolder, withIntermediateDirectories: true)
        for helper in helpers {
            FileManager.default.createFile(atPath: helperFolder.appendingPathComponent(helper).path, contents: Data())
        }
        return app
    }

    @Test(
        arguments: [
            ("Brave Browser", "Brave Browser Framework", ["app_mode_loader", "chrome_crashpad_handler"], true),
            ("Old Chromium", "Chromium Framework", ["app_mode_loader"], true),
            ("Electron App", "Electron Framework", ["app_shim_loader", "chrome_crashpad_handler"], true),
            ("Orion", "JavaScriptCore", ["jsc"], false),
            ("Empty Helpers", "Something", [], false),
        ] as [(String, String, [String], Bool)])
    func detectsChromium(name: String, framework: String, helpers: [String], isChromium: Bool) throws {
        let bundle = try app(name, framework: framework, helpers: helpers)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        #expect(AppAccessibility.isChromium(bundleURL: bundle) == isChromium)
    }

    @Test func appWithoutFrameworksIsNotChromium() {
        let bundle = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(!AppAccessibility.isChromium(bundleURL: bundle))
    }
}

extension IntegrationTests {
    /// The app-wide flags turned on for reading, on the host's own process.
    @MainActor
    struct AppAccessibilityFlagsTests {
        @Test func enablesOnlyWhatWasOffAndRestoresIt() throws {
            let pid = getpid()
            let app = AXElement.application(pid: pid)
            try #require((try? app.attribute(.enhancedUserInterface)) != true, "already on")
            let enabled = AppAccessibility.enable(pid: pid, flags: [.enhancedUserInterface])
            Teardown.add { AppAccessibility.restore(enabled, pid: pid) }
            #expect(enabled == [.enhancedUserInterface])
            #expect(try app.attribute(.enhancedUserInterface) == true)
            #expect(AppAccessibility.enable(pid: pid, flags: [.enhancedUserInterface]).isEmpty, "already on: nothing to restore")
            AppAccessibility.restore(enabled, pid: pid)
            #expect(try app.attribute(.enhancedUserInterface) != true)
        }
    }
}
