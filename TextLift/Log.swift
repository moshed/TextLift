import Foundation
import os

/// Diagnostics. Read with:
///   log stream --predicate 'subsystem == "com.dnz.lift"' --style compact
///   log show --predicate 'subsystem == "com.dnz.lift"' --last 10m --style compact
enum Log {
    static let capture = Logger(subsystem: "com.dnz.lift", category: "capture")
    static let ocr = Logger(subsystem: "com.dnz.lift", category: "ocr")
    static let notify = Logger(subsystem: "com.dnz.lift", category: "notify")

    /// Every capture is kept here so a failure can be inspected after the fact.
    static let lastCaptureURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("textlift-last-capture.png")
}
