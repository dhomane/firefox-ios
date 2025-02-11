// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import Shared
import WebKit
import CoreSpotlight
import SiteImageView

private let log = Logger.browserLogger

// A base protocol for something that can be cleared.
protocol Clearable {
    func clear() -> Success
    var label: String { get }
}

class ClearableError: MaybeErrorType {
    fileprivate let msg: String
    init(msg: String) {
        self.msg = msg
    }

    var description: String { return msg }
}

// Clears our browsing history, including favicons and thumbnails.
class HistoryClearable: Clearable {
    let profile: Profile
    let tabManager: TabManager
    let siteImageHandler: SiteImageHandler

    init(profile: Profile,
         tabManager: TabManager,
         siteImageHandler: SiteImageHandler = DefaultSiteImageHandler.factory()) {
        self.profile = profile
        self.tabManager = tabManager
        self.siteImageHandler = siteImageHandler
    }

    var label: String { .ClearableHistory }

    func clear() -> Success {
        // Treat desktop sites as part of browsing history.
        Tab.ChangeUserAgent.clear()

        // Clear everything in places
        return profile.places.deleteEverythingHistory().bindQueue(.main) { success in
            return self.clearAfterHistory(success: success)
        }
    }

    func clearAfterHistory(success: Maybe<Void>) -> Success {
        // Clear image data from Site Image Helper
        siteImageHandler.clearAllCaches()

        self.profile.recentlyClosedTabs.clearTabs()
        self.profile.places.deleteHistoryMetadataOlderThan(olderThan: INT64_MAX).uponQueue(.global(qos: .userInteractive)) { _ in }
        CSSearchableIndex.default().deleteAllSearchableItems()
        NotificationCenter.default.post(name: .PrivateDataClearedHistory, object: nil)
        log.debug("HistoryClearable succeeded: \(success).")

        self.tabManager.clearAllTabsHistory()

        return Deferred(value: success)
    }
}

// Clear the web cache. Note, this has to close all open tabs in order to ensure the data
// cached in them isn't flushed to disk.
class CacheClearable: Clearable {
    var label: String { .ClearableCache }

    func clear() -> Success {
        let dataTypes = Set([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast, completionHandler: {})

        MemoryReaderModeCache.sharedInstance.clear()
        DiskReaderModeCache.sharedInstance.clear()

        log.debug("CacheClearable succeeded.")
        return succeed()
    }
}

class SpotlightClearable: Clearable {
    var label: String { .ClearableSpotlight }

    func clear() -> Success {
        let deferred = Success()
        UserActivityHandler.clearSearchIndex { _ in
            deferred.fill(Maybe(success: ()))
        }
        return deferred
    }
}

// Removes all app cache storage.
class SiteDataClearable: Clearable {
    var label: String { .ClearableOfflineData }

    func clear() -> Success {
        let dataTypes = Set([WKWebsiteDataTypeOfflineWebApplicationCache])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast, completionHandler: {})

        log.debug("SiteDataClearable succeeded.")
        return succeed()
    }
}

// Remove all cookies stored by the site. This includes localStorage, sessionStorage, and WebSQL/IndexedDB.
class CookiesClearable: Clearable {
    var label: String { .ClearableCookies }

    func clear() -> Success {
        let dataTypes = Set([WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeIndexedDBDatabases])
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast, completionHandler: {})

        log.debug("CookiesClearable succeeded.")
        return succeed()
    }
}

class TrackingProtectionClearable: Clearable {
    // @TODO: re-using string because we are too late in cycle to change strings
    var label: String {
        return .SettingsTrackingProtectionSectionName
    }

    func clear() -> Success {
        let result = Success()
        ContentBlocker.shared.clearSafelist {
            result.fill(Maybe(success: ()))
        }
        return result
    }
}

// Clears our downloaded files in the `~/Documents/Downloads` folder.
class DownloadedFilesClearable: Clearable {
    var label: String { .ClearableDownloads }

    func clear() -> Success {
        if let downloadsPath = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Downloads"),
            let files = try? FileManager.default.contentsOfDirectory(
                at: downloadsPath,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles,
                          .skipsPackageDescendants,
                          .skipsSubdirectoryDescendants]) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        NotificationCenter.default.post(name: .PrivateDataClearedDownloadedFiles, object: nil)

        return succeed()
    }
}
