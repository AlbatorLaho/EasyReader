import Foundation
import os

/// `debug` is compiled out of Release (it may contain other apps' text); `error` is always logged, so keep other apps' content out of it.
struct Log: Sendable {
    private let logger: Logger

    private init(category: String) {
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EasyReader", category: category)
    }

    static let reader = Log(category: "Reader")
    static let speech = Log(category: "Speech")
    static let selector = Log(category: "Selector")
    static let accessibility = Log(category: "Accessibility")
    static let scroll = Log(category: "Scroll")
    static let app = Log(category: "App")
    static let nowPlaying = Log(category: "NowPlaying")
    static let settings = Log(category: "Settings")

    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
            let message = message()
            logger.debug("\(message, privacy: .public)")
        #endif
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
