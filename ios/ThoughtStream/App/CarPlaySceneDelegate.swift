import CarPlay
import UIKit

/// The CarPlay Audio surface (spec 0008): a recordings browser plus Now Playing.
///
/// The root is a `CPListTemplate` with two sections - a "Start a thought stream" row that calls the
/// same shared session starter the Record button and Siri use, and a row per note that HAS a
/// recording (title, date, duration), newest first, driven by the headless `RecordingsListModel`
/// over the shared `NoteStoreDriver`. Tapping a recording plays its `.m4a` through the shared
/// `NotePlaybackController` and pushes `CPNowPlayingTemplate`, whose transport (play / pause / skip)
/// is wired to the same controller that feeds `MPNowPlayingInfoCenter`. When the note list changes
/// (a saved session, a synced-in note), the list refreshes live.
///
/// GATED, PENDING APPLE APPROVAL. Apple grants the CarPlay entitlement only for specific app
/// CATEGORIES (audio, communication, navigation, EV, parking, and a few more). The CarPlay AUDIO
/// entitlement (`com.apple.developer.carplay-audio`) fits this app - it records and plays back the
/// user's voice notes - but is granted only on approval, so it is NOT declared on the shipping
/// target: the system never creates this scene, and the unsigned Simulator build and the App Store
/// build are unaffected. This code is ready the day Apple grants the entitlement; until then Siri is
/// the shippable hands-free-in-car path. Activating this needs the entitlement plus a CarPlay head
/// unit or the CarPlay simulator. See docs/carplay-audio-entitlement-request.md.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    /// The interface controller the system hands us on connect; retained so the template stays live.
    private var interfaceController: CPInterfaceController?
    /// The recordings browser model, built from the shared dependencies on connect. Nil until then.
    private var recordings: RecordingsListModel?
    /// The shared playback controller for the CarPlay surface. One controller feeds `CPNowPlayingTemplate`
    /// and `MPNowPlayingInfoCenter`, driven by the row tap and the Now Playing transport buttons.
    private var playback: NotePlaybackController?
    /// The live root list template, kept so a driver change can rebuild its sections in place.
    private var rootTemplate: CPListTemplate?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        // Reach the live dependencies through the composition root: the CarPlay scene is built by the
        // system outside the SwiftUI tree, so it cannot receive them by injection (the same bridge the
        // session starter uses). Fall back to a local store if the root has not resolved yet (rare -
        // the app resolves at launch); the browser then lists local recordings.
        let store = AppDependencies.shared?.noteStore ?? NoteStore()
        let observer = AppDependencies.shared?.noteObserver
        let recordings = RecordingsListModel(store: store, observer: observer)
        self.recordings = recordings
        self.playback = NotePlaybackController(resolver: StoreAudioURLResolver(store: store))

        let root = CPListTemplate(title: "Thought Stream", sections: [])
        self.rootTemplate = root
        interfaceController.setRootTemplate(root, animated: false, completion: nil)

        // Rebuild the list whenever the recordings change, and do the initial load.
        recordings.onChange = { [weak self] in self?.refreshRootSections() }
        refreshRootSections()
        Task { await recordings.start() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        recordings?.stop()
        recordings = nil
        playback?.stop()
        playback = nil
        rootTemplate = nil
        self.interfaceController = nil
    }

    // MARK: - Templates

    /// Rebuild the root list's sections from the current recordings: a Start row on top, then one row
    /// per recording. Called on connect and on every driver change, so the list stays live.
    private func refreshRootSections() {
        rootTemplate?.updateSections(makeSections())
    }

    /// Build the "Start a thought stream" row, whose tap requests a new session through `onStart`.
    /// Static and closure-driven so the routing (a tap starts a session) is unit-testable without a
    /// connected CarPlay scene; production passes the shared `AppDependencies.sessionStarter`.
    static func makeStartItem(onStart: @escaping () -> Void) -> CPListItem {
        let start = CPListItem(text: "Start a thought stream", detailText: "Begin a new note by voice")
        start.handler = { _, completion in
            onStart()
            completion()
        }
        return start
    }

    private func makeSections() -> [CPListSection] {
        let start = Self.makeStartItem { AppDependencies.sessionStarter.startNewSession() }
        let startSection = CPListSection(items: [start])

        let entries = recordings?.entries ?? []
        let items: [CPListItem] = entries.map { entry in
            let item = CPListItem(text: entry.title, detailText: entry.detail)
            item.handler = { [weak self] _, completion in
                self?.playAndShowNowPlaying(entry.note)
                completion()
            }
            return item
        }
        // Even with no recordings yet, keep the section so the header text explains the empty state.
        let recordingsSection = CPListSection(
            items: items,
            header: "Recordings",
            sectionIndexTitle: nil
        )
        return [startSection, recordingsSection]
    }

    /// Play the note through the shared controller and push the CarPlay Now Playing template, whose
    /// transport buttons drive the same controller (which also feeds `MPNowPlayingInfoCenter`).
    private func playAndShowNowPlaying(_ note: Note) {
        playback?.play(note: note)
        configureNowPlayingButtons()
        let nowPlaying = CPNowPlayingTemplate.shared
        // Only push it if it is not already the top template, so repeated taps do not stack it.
        if interfaceController?.topTemplate !== nowPlaying {
            interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    /// Wire the CarPlay Now Playing transport buttons to the shared controller. Play/pause is the
    /// system default (CarPlay renders it from `MPNowPlayingInfoCenter` + the remote commands the
    /// controller registered); the added buttons are skip-back and skip-forward.
    private func configureNowPlayingButtons() {
        let back = CPNowPlayingImageButton(image: Self.symbol("gobackward.15")) { [weak self] _ in
            self?.playback?.skip(by: -SystemRemoteCommandRegistrar.skipInterval)
        }
        let forward = CPNowPlayingImageButton(image: Self.symbol("goforward.15")) { [weak self] _ in
            self?.playback?.skip(by: SystemRemoteCommandRegistrar.skipInterval)
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([back, forward])
    }

    /// A CarPlay button glyph from an SF Symbol, falling back to an empty image if the symbol is
    /// unavailable so a missing glyph never crashes the head unit.
    private static func symbol(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
    }
}
