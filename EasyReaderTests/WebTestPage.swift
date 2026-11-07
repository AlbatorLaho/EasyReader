import AppKit
import Foundation
import WebKit

/// A web page in another process, for `WebAreaReadableElementTests`: a `WKWebView` exposes the same `AXWebArea` as
/// Safari. It can't live in the test host's own process: a web area's frame, parent and window are answered through the
/// hosting app's main run loop, so reading a `WKWebView` in-process blocks ~1.5 s per such AX call (the caller holds the
/// main thread) and then fails.
///
/// This file is compiled twice: into the test bundle (for `launch()`), and by `launch()` itself with `swiftc` into a
/// standalone executable whose entry point calls `run()`, built once per test run from this source file (`#filePath`).
enum WebTestPage {
    static let title = "EasyReader Web Test Page"

    static let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>EasyReader Test Page</title>
        <style>
          body { font: 20px/1.5 -apple-system, sans-serif; max-width: 40em; margin: 2em auto; padding: 0 1em; }
          textarea { width: 100%; height: 6em; font: inherit; }
        </style>
        </head>
        <body>
        <h1>EasyReader test page</h1>
        <p>This page tests reading web content. Select a sentence, then press the start shortcut.
        Reading should continue sentence by sentence, with <a href="https://example.com">links</a>,
        <b>bold</b> and <i>italic</i> text read inline.</p>
        <p>Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀. This sentence comes after them.</p>
        <h2>A text area inside the page</h2>
        <textarea>Text area sentence one. Text area sentence two.</textarea>
        <h2>Scrolling</h2>
        \((1...40).map { "<p>Paragraph \($0) of filler text to make the page scroll. It has two sentences.</p>" }.joined(separator: "\n"))
        <p>The end of the test page.</p>
        </body>
        </html>
        """

    /// Entry point of the fixture executable: one window showing `html`.
    @MainActor
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = webView
        webView.loadHTMLString(html, baseURL: nil)
        window.makeKeyAndOrderFront(nil)
        app.run()
        exit(0)
    }

    private struct BuildFailed: Error, CustomStringConvertible {
        let output: String
        var description: String { "building the web test page failed:\n\(output)" }
    }

    /// Builds the fixture executable (once per source version) and starts it.
    static func launch() throws -> Process {
        let process = Process()
        process.executableURL = try executable()
        try process.run()
        return process
    }

    private static func executable(source: String = #filePath) throws -> URL {
        let sourceURL = URL(fileURLWithPath: source)
        let modified = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyReaderWebTestPage-\(Int(modified.timeIntervalSince1970))")
        let executable = directory.appendingPathComponent("WebTestPage")
        if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let main = directory.appendingPathComponent("main.swift")
        try "WebTestPage.run()\n".write(to: main, atomically: true, encoding: .utf8)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["swiftc", "-swift-version", "6", sourceURL.path, main.path, "-o", executable.path]
        let pipe = Pipe()
        build.standardOutput = pipe
        build.standardError = pipe
        try build.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        build.waitUntilExit()
        guard build.terminationStatus == 0 else { throw BuildFailed(output: output) }
        return executable
    }
}
