//
//  BrowserHelper.swift
//  Menu Bar Usage for Claude
//
//  Opens web links in the preferred browser.
//

import AppKit

/// Opens web URLs in the user's preferred browser (or the system default).
enum BrowserHelper {
    /// A browser installed on this Mac that can handle `https` URLs.
    struct BrowserInfo: Identifiable, Hashable {
        let id: String   // bundle identifier
        let name: String
        let url: URL
    }

    /// Returns every app registered to handle `https` URLs, sorted by
    /// display name. Computed on demand — the list is short and the
    /// Settings picker is the only caller.
    static func installedBrowsers() -> [BrowserInfo] {
        let dummy = URL(string: "https://example.com")!
        return NSWorkspace.shared.urlsForApplications(toOpen: dummy)
            .compactMap { appURL in
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                              ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                else { return nil }
                return BrowserInfo(id: bundleID, name: name, url: appURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Opens `url` in the preferred browser, falling back to the system
    /// default if no preference is set or the chosen browser can't be found.
    static func open(_ url: URL) {
        let bundleID = UserDefaults.standard[SettingsKeys.preferredBrowserBundleID]
        if !bundleID.isEmpty,
           let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
