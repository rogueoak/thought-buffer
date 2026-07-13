import Foundation

/// Resolves the app's iCloud ubiquity container so the composition root can decide whether to
/// use iCloud storage or fall back to local. Behind a protocol so the selection logic is
/// unit-testable without a real iCloud account: tests inject a stub that resolves a URL (iCloud
/// present) or nil (iCloud absent).
protocol UbiquityContainerProviding: Sendable {
    /// The ubiquity container identifier to resolve. `nil` asks the system for the app's default
    /// container declared in entitlements.
    var containerIdentifier: String? { get }

    /// Resolve the container's root URL, or nil when iCloud is unavailable (not signed in, no
    /// provisioning, or the Simulator with no account). This call can block, so it is async and
    /// callers must run it off the main actor.
    func containerURL() async -> URL?
}

/// Production provider backed by `FileManager`. Resolving the container calls
/// `url(forUbiquityContainerIdentifier:)`, which can block on the sync daemon, so it runs on a
/// background executor and is exposed as `async`.
struct FileManagerUbiquityContainerProvider: UbiquityContainerProviding {
    let containerIdentifier: String?

    /// Default to the app's iCloud container id declared in `ios/project.yml` entitlements.
    init(containerIdentifier: String? = "iCloud.com.rogueoak.thoughtstream") {
        self.containerIdentifier = containerIdentifier
    }

    func containerURL() async -> URL? {
        let identifier = containerIdentifier
        // Hop off the main actor: url(forUbiquityContainerIdentifier:) can block for a while.
        return await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: identifier)
        }.value
    }
}
