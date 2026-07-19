import Foundation
import MediaPlayer

/// The Now Playing metadata a playback surface publishes: what is playing and where it is. Kept as a
/// small value so the controller can build it once and hand it to whatever writes the system center,
/// and so tests can assert exactly what was published without a real `MPNowPlayingInfoCenter`.
struct NowPlayingInfo: Equatable {
    /// The thought's title, shown as the Now Playing track title on the lock screen / CarPlay.
    let title: String
    /// Total recording length in seconds (`MPMediaItemPropertyPlaybackDuration`).
    let duration: Double
    /// Seconds elapsed (`MPNowPlayingInfoPropertyElapsedPlaybackTime`).
    let elapsed: Double
    /// 1 while playing, 0 while paused (`MPNowPlayingInfoPropertyPlaybackRate`), so the system shows
    /// the right transport state and does not advance a paused elapsed time.
    let rate: Double
}

/// Writes (and clears) the system Now Playing metadata. A protocol so the playback controller can be
/// unit-tested with a spy: the production impl talks to `MPNowPlayingInfoCenter.default()`, which the
/// lock screen, Control Center, and a CarPlay head unit all render. Main-actor isolated because the
/// controller that drives it is.
@MainActor
protocol NowPlayingInfoWriting: AnyObject {
    /// Publish `info` as the current Now Playing item, or clear it when `info` is nil (playback
    /// stopped).
    func update(_ info: NowPlayingInfo?)
}

/// The production writer over `MPNowPlayingInfoCenter`.
@MainActor
final class SystemNowPlayingInfoWriter: NowPlayingInfoWriting {
    func update(_ info: NowPlayingInfo?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
        ]
    }
}

/// The remote transport commands a playback controller responds to. Registering a set of handlers
/// here wires the lock screen / Control Center / CarPlay transport buttons to the same controller
/// code the in-app buttons drive. A protocol so registration is unit-testable with a spy that
/// captures and can fire each handler, with no real `MPRemoteCommandCenter`.
@MainActor
protocol RemoteCommandRegistering: AnyObject {
    /// Wire the transport commands. Each closure runs on the main actor when the system (or a spy)
    /// fires that command. `skip` receives the configured skip interval in seconds. Idempotent: a
    /// second registration replaces the handlers rather than stacking them.
    func register(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        toggle: @escaping () -> Void,
        stop: @escaping () -> Void,
        skipForward: @escaping () -> Void,
        skipBackward: @escaping () -> Void
    )

    /// Drop all registered handlers and disable the commands, so a torn-down controller leaves no
    /// live transport wired to it.
    func unregisterAll()
}

/// The default relative-skip interval in seconds, offered to the system so the lock screen shows a
/// skip button with this label and CarPlay maps its skip controls to it. A nonisolated constant so it
/// can be a default argument for the controller without an actor hop.
let defaultSkipInterval: Double = 15

/// The production registrar over `MPRemoteCommandCenter`.
@MainActor
final class SystemRemoteCommandRegistrar: RemoteCommandRegistering {
    /// The skip interval offered to the system (see `defaultSkipInterval`).
    static let skipInterval = defaultSkipInterval

    private var targets: [(MPRemoteCommand, Any)] = []

    func register(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        toggle: @escaping () -> Void,
        stop: @escaping () -> Void,
        skipForward: @escaping () -> Void,
        skipBackward: @escaping () -> Void
    ) {
        unregisterAll()
        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { play() }
        add(center.pauseCommand) { pause() }
        add(center.togglePlayPauseCommand) { toggle() }
        add(center.stopCommand) { stop() }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipForwardCommand) { skipForward() }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.skipBackwardCommand) { skipBackward() }
    }

    /// Enable a command and add a main-actor handler that runs `body` and reports success, tracking
    /// the target so `unregisterAll` can remove it.
    private func add(_ command: MPRemoteCommand, _ body: @escaping () -> Void) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            body()
            return .success
        }
        targets.append((command, target))
    }

    func unregisterAll() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
    }
}
