import XCTest
@testable import ThoughtStream

/// The pure metadata->thoughts mapping used by the NSMetadataQuery observer, exercised with stub
/// items so the enumeration and download-trigger logic is provable without real iCloud.
final class UbiquitousThoughtMappingTests: XCTestCase {
    private func item(_ name: String, downloaded: Bool) -> UbiquitousThoughtMapping.Item {
        let url = URL(fileURLWithPath: "/iCloud/Documents/ThoughtStream/\(name)")
        return .init(url: url, isDownloaded: downloaded)
    }

    func testMapsOnlyMarkdownFilesSortedStably() {
        let items = [
            item("b.md", downloaded: true),
            item("readme.txt", downloaded: true),
            item("a.md", downloaded: true),
            item("c.md", downloaded: false),
        ]
        let urls = UbiquitousThoughtMapping.thoughtURLs(from: items)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.md", "b.md", "c.md"])
    }

    func testEmptyItemsProducesNoThoughts() {
        XCTAssertTrue(UbiquitousThoughtMapping.thoughtURLs(from: []).isEmpty)
    }

    func testUrlsNeedingDownloadAreTheNotYetLocalMarkdownFiles() {
        let items = [
            item("here.md", downloaded: true),
            item("synced-in.md", downloaded: false),
            item("other.txt", downloaded: false),
            item("also-remote.md", downloaded: false),
        ]
        let needing = UbiquitousThoughtMapping.urlsNeedingDownload(from: items)
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(needing, ["also-remote.md", "synced-in.md"])
    }

    func testAllDownloadedNeedsNoDownloads() {
        let items = [item("a.md", downloaded: true), item("b.md", downloaded: true)]
        XCTAssertTrue(UbiquitousThoughtMapping.urlsNeedingDownload(from: items).isEmpty)
    }
}
