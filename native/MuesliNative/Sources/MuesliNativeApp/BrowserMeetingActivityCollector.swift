import AppKit
import ApplicationServices
import Foundation

struct RunningAppSnapshot: Sendable {
    let bundleID: String
    let appName: String
    let processIdentifier: pid_t
    let isActive: Bool
}

final class BrowserMeetingActivityCollector {
    private let browserBundleIDs = Set(MeetingCandidateResolver.browserApps.keys)
    private let cachedMeetingTTL: TimeInterval = 8
    private var cachedMeetings: [String: CachedBrowserMeeting] = [:]

    func collect(runningApps: [RunningAppSnapshot]) async -> [BrowserMeetingContext] {
        let now = Date()
        let browserApps = runningApps.filter { browserBundleIDs.contains($0.bundleID) }
        let runningBrowserIDs = Set(browserApps.map(\.bundleID))

        var liveMeetings: [BrowserMeetingContext] = []
        for app in browserApps {
            guard let normalized = await normalizedFocusedURL(for: app) else {
                if app.isActive {
                    cachedMeetings.removeValue(forKey: app.bundleID)
                }
                continue
            }

            let context = BrowserMeetingContext(
                bundleID: app.bundleID,
                appName: app.appName,
                pid: app.processIdentifier,
                url: normalized.url,
                normalizedID: normalized.id,
                platform: normalized.platform,
                isFocused: app.isActive
            )
            cachedMeetings[app.bundleID] = CachedBrowserMeeting(context: context, observedAt: now)
            liveMeetings.append(context)
        }

        let liveBundleIDs = Set(liveMeetings.map(\.bundleID))
        cachedMeetings = cachedMeetings.filter { bundleID, cached in
            runningBrowserIDs.contains(bundleID) && now.timeIntervalSince(cached.observedAt) <= cachedMeetingTTL
        }

        let cachedOnlyMeetings = cachedMeetings.values
            .filter { !liveBundleIDs.contains($0.context.bundleID) }
            .map { cached in
                BrowserMeetingContext(
                    bundleID: cached.context.bundleID,
                    appName: cached.context.appName,
                    pid: cached.context.pid,
                    url: cached.context.url,
                    normalizedID: cached.context.normalizedID,
                    platform: cached.context.platform,
                    isFocused: false
                )
            }

        return liveMeetings + cachedOnlyMeetings
    }

    private func normalizedFocusedURL(for app: RunningAppSnapshot) async -> NormalizedMeetingURL? {
        if let normalized = normalizedAXDocumentURL(for: app) {
            return normalized
        }

        // Query the browser's active tab even after another app/overlay becomes
        // frontmost. Strict URL normalization plus resolver media checks keep
        // background meeting tabs from prompting by themselves.
        guard let url = await activeBrowserURLViaAppleScript(bundleID: app.bundleID) else {
            return nil
        }
        return MeetingURLNormalizer.normalize(url)
    }

    private func normalizedAXDocumentURL(for app: RunningAppSnapshot) -> NormalizedMeetingURL? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }

        let axWindow = (window as! AXUIElement)
        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &documentRef) == .success,
              let rawURL = documentRef as? String else {
            return nil
        }

        return MeetingURLNormalizer.normalize(rawURL)
    }

    @MainActor
    private func activeBrowserURLViaAppleScript(bundleID: String) -> String? {
        let source: String
        switch bundleID {
        case "com.apple.Safari":
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of current tab of front window
            end tell
            """
        case "com.google.Chrome", "com.brave.Browser", "company.thebrowser.Browser", "com.microsoft.edgemac":
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        default:
            return nil
        }

        var errorInfo: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue,
              !output.isEmpty else {
            return nil
        }
        return output
    }
}

private struct CachedBrowserMeeting {
    let context: BrowserMeetingContext
    let observedAt: Date
}
