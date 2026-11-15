import Cocoa

/// App-wide AX flags that make some apps (like Chromium) build their full AX tree.
@MainActor
enum AppAccessibility {
    private static let flags: [AXAttribute<Bool>] = [.manualAccessibility, .enhancedUserInterface]

    /// Turns on the flags (default: all) that are off; returns those it turned on.
    /// `unreadable`: also sets flags the app can't report (Electron's `AXManualAccessibility`), counted as turned on.
    static func enable(pid: pid_t, flags: [AXAttribute<Bool>] = flags, unreadable: Bool = true) -> [AXAttribute<Bool>] {
        let app = AXElement.application(pid: pid)
        var enabled: [AXAttribute<Bool>] = []
        for flag in flags {
            let current = try? app.attribute(flag)
            if current == true || (current == nil && !unreadable) { continue }
            do {
                try app.set(flag, to: true)
                if (try? app.attribute(flag)) != false { enabled.append(flag) }
            } catch {
                // Chromium reports failure for `AXEnhancedUserInterface` but applies it
                if (try? app.attribute(flag)) == true { enabled.append(flag) }
            }
        }
        return enabled
    }

    static func restore(_ flags: [AXAttribute<Bool>], pid: pid_t) {
        let app = AXElement.application(pid: pid)
        // VoiceOver may have turned it on meanwhile, and needs it
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        for flag in flags where !(voiceOver && flag == .enhancedUserInterface) {
            try? app.set(flag, to: false)
        }
    }

    /// Chromium-based browsers and Electron apps.
    // Not just any `Helpers` folder: WebKit's JavaScriptCore has one too (Orion)
    nonisolated static func isChromium(_ app: NSRunningApplication) -> Bool {
        app.bundleURL.map { isChromium(bundleURL: $0) } ?? false
    }

    nonisolated static func isChromium(bundleURL: URL) -> Bool {
        frameworks(of: bundleURL).contains { framework in
            framework.lastPathComponent == "Electron Framework.framework"
                || hasHelper("app_mode_loader", in: framework) || hasHelper("chrome_crashpad_handler", in: framework)
        }
    }

    private nonisolated static func frameworks(of bundleURL: URL) -> [URL] {
        let folder = bundleURL.appendingPathComponent("Contents/Frameworks")
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "framework" }
    }

    private nonisolated static func hasHelper(_ name: String, in framework: URL) -> Bool {
        FileManager.default.fileExists(atPath: framework.appendingPathComponent("Versions/Current/Helpers/\(name)").path)
    }
}
