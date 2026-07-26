import Foundation

/// Watches the iCloud thoughts folder for changes - external edits, or files synced in from another
/// device - so the Stream list can refresh without a manual reload. Behind a protocol so the
/// Stream list depends on an abstraction and tests drive it with a stub (no real iCloud).
///
/// The production implementation is `MetadataUbiquitousThoughtObserver`, backed by `NSMetadataQuery`
/// over `NSMetadataQueryUbiquitousDocumentsScope`. It also triggers downloads for items that have
/// synced their metadata but not yet their contents.
protocol UbiquitousThoughtObserving: AnyObject {
    /// Called on the main actor whenever the set of iCloud thought files changes. The observer
    /// coalesces query updates; the receiver typically reloads via its `ThoughtStoring`.
    var onChange: (() -> Void)? { get set }

    /// Begin observing. Idempotent; safe to call once when the Stream list appears.
    func start()

    /// Stop observing and tear down the query.
    func stop()
}

/// Pure mapping from iCloud metadata items to the thought file URLs the store should load, plus the
/// URLs that still need downloading. Split out from the live query so it is unit-testable with a
/// stub feeding item descriptors, with no real `NSMetadataQuery`.
enum UbiquitousThoughtMapping {
    /// A minimal view of one metadata item: its file URL and whether its contents are downloaded.
    struct Item {
        let url: URL
        /// True when the file's current version is present locally
        /// (`NSMetadataUbiquitousItemDownloadingStatusCurrent`).
        let isDownloaded: Bool
    }

    /// The `.md` thought files among the items, sorted by last path component for a stable order.
    static func thoughtURLs(from items: [Item]) -> [URL] {
        items
            .map(\.url)
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The `.md` thought files that are not yet downloaded and so need a download kicked off.
    static func urlsNeedingDownload(from items: [Item]) -> [URL] {
        items
            .filter { $0.url.pathExtension.lowercased() == "md" && !$0.isDownloaded }
            .map(\.url)
    }
}

/// Live observer backed by `NSMetadataQuery`. Enumerates iCloud thought documents, triggers
/// downloads for not-yet-local items, and fires `onChange` (coalesced, on the main actor) so the
/// Stream list reloads through its store.
final class MetadataUbiquitousThoughtObserver: NSObject, UbiquitousThoughtObserving {
    var onChange: (() -> Void)?

    private let query: NSMetadataQuery
    private let fileManager = FileManager.default
    private var isRunning = false

    override init() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Only markdown thought files under the container Documents area.
        query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)
        self.query = query
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        center.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        query.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
    }

    deinit {
        stop()
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var items: [UbiquitousThoughtMapping.Item] = []
        for raw in query.results {
            guard let item = raw as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let isDownloaded = status == NSMetadataUbiquitousItemDownloadingStatusCurrent
            items.append(.init(url: url, isDownloaded: isDownloaded))
        }

        // Kick downloads for anything present in metadata but not yet local, so external thoughts
        // become readable.
        for url in UbiquitousThoughtMapping.urlsNeedingDownload(from: items) {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }

        // NSMetadataQuery delivers its notifications on the thread that started the query, which is
        // the main thread (the observer is started from the Stream list's main-actor `.task`), so
        // `onChange` - documented to fire on the main actor - can be called directly with no hop.
        onChange?()
    }
}
