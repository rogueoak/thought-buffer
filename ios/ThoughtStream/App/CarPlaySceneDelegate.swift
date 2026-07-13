import CarPlay
import UIKit

/// The CarPlay scene: a minimal template with a "Start a thought stream" action that calls the same
/// shared session starter the Record button and Siri use.
///
/// GATED, PENDING APPLE APPROVAL. Apple grants the CarPlay entitlement only for specific app
/// CATEGORIES (audio, communication, navigation, EV, parking, and a few more). A dictation / notes
/// app is not one of them, so the CarPlay entitlement is generally unavailable for distribution
/// here. No CarPlay entitlement is declared on the shipping target, so the system never creates
/// this scene: it stays dormant and the unsigned Simulator build and App Store build are
/// unaffected. The code is ready the day Apple grants the entitlement (or the category changes);
/// until then Siri is the shippable hands-free-in-car path. Activating this needs the entitlement
/// plus a CarPlay head unit or the CarPlay simulator.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    /// The interface controller the system hands us on connect; retained so the template stays live.
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(makeRootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    /// A single-row list: tapping "Start a thought stream" requests the shared session route, so the
    /// phone opens a fresh dictation session - the same start the Record button and Siri trigger.
    private func makeRootTemplate() -> CPListTemplate {
        let start = CPListItem(text: "Start a thought stream", detailText: "Begin a new note by voice")
        start.handler = { _, completion in
            Task { @MainActor in
                AppDependencies.sessionStarter.startNewSession()
                completion()
            }
        }
        let section = CPListSection(items: [start])
        return CPListTemplate(title: "Thought Stream", sections: [section])
    }
}
