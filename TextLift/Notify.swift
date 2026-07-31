import AppKit
import UserNotifications

/// Banner showing what just got copied, so a capture can be confirmed without
/// switching to the result window.
enum Notify {
    private static let categoryID = "textlift.capture"
    private static let appName = "TextLift"

    /// Ask once at launch. Notifications need a signed, bundled app — which is
    /// why `redeploy.sh` uses the Developer ID identity rather than ad-hoc.
    ///
    /// On macOS 26 this reports `granted=false, "Notifications are not allowed
    /// for this application"` for a directly-installed (non-App-Store) app and
    /// never shows a prompt — but banners are still delivered. Verified in the
    /// system log: `usernoted` reports the record "successfully processed by
    /// pipeline" and "Delivering ... to [ .alert .lockScreen .notificationCenter ]"
    /// even with `authorizationStatus: Denied`. So the result is logged and
    /// otherwise ignored — gating posts on it would disable a working feature.
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            Log.notify.info("status before request = \(s.authorizationStatus.rawValue)")
        }
        center
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                Log.notify.info("""
                    authorization granted=\(granted) \
                    error=\(error?.localizedDescription ?? "none", privacy: .public)
                    """)
            }
    }

    static func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [],
                                   intentIdentifiers: [], options: [])
        ])
    }

    /// `title` carries the summary, `body` the text itself. macOS truncates the
    /// body to a few lines in the banner and shows the rest on hover, so there's
    /// no point trimming hard — but a runaway capture shouldn't be sent whole.
    /// Posts a sample banner. Exposed in Settings so notification delivery can be
    /// checked without making a capture, and driven by `TEXTLIFT_TEST_NOTIFY=1`
    /// for automated checks.
    static func test() {
        copied("The quick brown fox jumps over the lazy dog.")
    }

    static func nothingFound() {
        let content = UNMutableNotificationContent()
        content.title = appName
        content.body = "No text found in that selection."
        content.categoryIdentifier = categoryID
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Title is just the app name; the body is the captured text and nothing
    /// else. The char count / confidence subtitle only got in the way of reading
    /// what was actually copied. macOS truncates the body in the banner and shows
    /// the rest on hover, so there's no point trimming hard — but a runaway
    /// capture shouldn't be sent whole.
    static func copied(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = appName
        content.body = String(text.prefix(600))
        content.categoryIdentifier = categoryID
        content.sound = nil

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.notify.error("post failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.notify.info("posted")
            }
        }
    }
}

/// What to do when a captured QR code turns out to hold a link.
enum LinkPolicy: String, CaseIterable {
    case never, ask, always

    var label: String {
        switch self {
        case .never:  return "Never"
        case .ask:    return "Ask first"
        case .always: return "Open it"
        }
    }
}

enum QRLink {
    /// The first payload that is a real web link.
    ///
    /// Deliberately limited to http/https. A QR code is untrusted input from
    /// whatever was on screen, and handing an arbitrary scheme to
    /// `NSWorkspace.open` would let one launch other apps or trigger system
    /// handlers.
    static func firstWebLink(in codes: [String]) -> URL? {
        for code in codes {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil
            else { continue }
            return url
        }
        return nil
    }
}
