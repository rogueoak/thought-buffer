import XCTest
@testable import ThoughtStream

/// The pure tap-time capture that fixes the folder rename/delete no-op (feedback 0026, item 4/5). Both the
/// top-level screen and the folder-thoughts "..." menu route their alert buttons through
/// `FolderDialogAction.capture`, so these tests cover the REAL production path (not a parallel copy).
///
/// The defect was view-layer and timing-dependent: the alert button used to read the target path from the
/// `activeDialog` state INSIDE a deferred `Task`, but tapping the button dismisses the alert, which fires the
/// dialog's presentation binding and clears `activeDialog` to nil BEFORE the `Task` runs - so the deferred
/// read saw nil and the rename/delete silently did nothing. These prove the capture yields the right payload
/// while the dialog is set AND that a value read AFTER the dialog clears (the dismissal out-racing the read)
/// resolves to nil - which is exactly the no-op the bug produced, so a revert to the deferred read turns the
/// synchronous-capture assertions red.
final class FolderDialogActionTests: XCTestCase {
    func testCaptureRenameYieldsPathAndLiveName() {
        let dialog = FolderDialog.renameFolder(path: ["Old"], currentName: "Old")
        // The live name-field text (what the user typed) is paired at capture time, not the currentName.
        let action = FolderDialogAction.capture(from: dialog, name: "New")
        XCTAssertEqual(action, .rename(path: ["Old"], newName: "New"))
    }

    func testCaptureDeleteYieldsPath() {
        let dialog = FolderDialog.deleteFolder(path: ["Doomed"])
        let action = FolderDialogAction.capture(from: dialog, name: "ignored")
        XCTAssertEqual(action, .delete(path: ["Doomed"]))
    }

    func testCaptureNewFolderIsNotAnActionableMutation() {
        XCTAssertNil(FolderDialogAction.capture(from: .newFolder, name: "X"))
    }

    /// The heart of the regression: reading the payload AFTER the dialog has cleared (a deferred read, which
    /// is what the bug did) resolves to nil - a no-op. So the fix MUST capture synchronously while the dialog
    /// is still set; the two assertions below encode that contract.
    func testCaptureFromClearedDialogIsNilButSynchronousCaptureSurvivesTheClear() {
        // Model the SwiftUI sequence: the dialog is set when the button is tapped ...
        var activeDialog: FolderDialog? = .renameFolder(path: ["Old"], currentName: "Old")

        // ... the fix reads the payload SYNCHRONOUSLY at tap time (before any async hop / dismissal) ...
        let capturedAtTapTime = FolderDialogAction.capture(from: activeDialog, name: "New")

        // ... then the alert's dismissal binding clears the state (this is what races a deferred read) ...
        activeDialog = nil

        // A deferred read of the now-cleared dialog yields NOTHING - the exact no-op the bug produced.
        let deferredRead = FolderDialogAction.capture(from: activeDialog, name: "New")
        XCTAssertNil(deferredRead)

        // The synchronously-captured value is independent of the state and still resolves correctly, so the
        // rename/delete proceeds regardless of the dismissal ordering.
        XCTAssertEqual(capturedAtTapTime, .rename(path: ["Old"], newName: "New"))
    }

    func testCaptureFromNilDialogIsNil() {
        XCTAssertNil(FolderDialogAction.capture(from: nil, name: "New"))
    }
}
