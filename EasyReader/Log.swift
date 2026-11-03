//
//  Log.swift
//  EasyReader
//

import Foundation
import os

/// App logging via unified logging (`Logger`).
///
/// - `debug` messages are compiled out of Release builds: they may include positions or text read
///   from other apps, which shouldn't end up in a user's system log.
/// - `error` messages are always logged; keep them free of other apps' content.
///
/// View in Xcode's console, or stream while running a Debug build:
///
///     log stream --level debug --predicate 'subsystem == "HawkRaven.EasyReader.debug"'
struct Log {
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

    /// Debug builds only. The message is not evaluated in Release.
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
