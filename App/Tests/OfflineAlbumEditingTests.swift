import Foundation
import TesseraeKit
import Testing
@testable import Tesserae_Companion

@Suite("Offline Album editing")
struct OfflineAlbumEditingTests {
    @Test("Name padding does not require saving", arguments: ["Family", " Family ", "\nFamily\t"])
    func namePaddingIsNotAChange(name: String) {
        var draft = populatedDraft()
        let baseline = draft
        draft.name = name

        #expect(!draft.hasChanges(comparedTo: baseline))
        #expect(!offlineAlbumShouldShowReview(isExistingAlbum: true, draft: draft, baseline: baseline))
        #expect(draft.albumDraft.name == "Family")
    }

    @Test("Reselecting the same displays is not a change", arguments: [
        ["desk", "kitchen"], ["kitchen", "desk"], ["kitchen", "desk", "kitchen"],
    ])
    func displaySelectionIsASet(deviceIDs: [String]) {
        var draft = populatedDraft()
        let baseline = draft
        draft.deviceIDs = deviceIDs

        #expect(!draft.hasChanges(comparedTo: baseline))
        #expect(!offlineAlbumShouldShowReview(isExistingAlbum: true, draft: draft, baseline: baseline))
    }

    @Test("Every saved setting participates in the exit and Review decision", arguments: Change.allCases)
    func configurationChangesRequireReview(change: Change) {
        let baseline = populatedDraft()
        let draft = change.applied(to: baseline)

        #expect(draft.hasChanges(comparedTo: baseline))
        #expect(offlineAlbumShouldShowReview(isExistingAlbum: true, draft: draft, baseline: baseline))
    }

    @Test("Changing and restoring the selection and photo order clears the draft")
    func restoredConfigurationIsClean() {
        let baseline = populatedDraft()
        var draft = baseline
        draft.deviceIDs.removeFirst()
        draft.order.reverse()
        #expect(draft.hasChanges(comparedTo: baseline))

        draft.deviceIDs.append("desk")
        draft.order.reverse()
        #expect(!draft.hasChanges(comparedTo: baseline))
        #expect(!offlineAlbumShouldShowReview(isExistingAlbum: true, draft: draft, baseline: baseline))
    }

    @Test("Folder order and explicit order remain distinct even when they currently look the same")
    func folderOrderIsAnExplicitChoice() {
        let baseline = populatedDraft()
        var draft = baseline
        draft.order = []

        #expect(offlineAlbumResolvedPhotoOrder(explicitOrder: draft.order, folderOrder: ["one", "two"]) == ["one", "two"])
        #expect(draft.hasChanges(comparedTo: baseline))
        #expect(draft.albumDraft.order.isEmpty)
        #expect(baseline.albumDraft.order == ["one", "two"])
    }

    @Test("A fresh Album can be reviewed without counting its defaults as unsaved edits")
    func newAlbumDefaultsAreClean() {
        let draft = OfflineAlbumEditorDraft(folderName: "Family", imageIDs: ["one", "two"])

        #expect(!draft.hasChanges(comparedTo: draft))
        #expect(offlineAlbumShouldShowReview(isExistingAlbum: false, draft: draft, baseline: draft))
    }

    private func populatedDraft() -> OfflineAlbumEditorDraft {
        var draft = OfflineAlbumEditorDraft(folderName: "Family", imageIDs: ["one", "two"])
        draft.deviceIDs = ["desk", "kitchen"]
        return draft
    }

    enum Change: CaseIterable, Sendable {
        case name, enabled, displays, photoOrder, fit, playbackMode, interval, repeatMode

        func applied(to original: OfflineAlbumEditorDraft) -> OfflineAlbumEditorDraft {
            var draft = original
            switch self {
            case .name: draft.name = "Holiday"
            case .enabled: draft.enabled = false
            case .displays: draft.deviceIDs = ["desk"]
            case .photoOrder: draft.order = ["two", "one"]
            case .fit: draft.fit = .fit
            case .playbackMode: draft.playbackMode = .shuffle
            case .interval: draft.intervalSeconds = 3_600
            case .repeatMode: draft.repeatMode = .once
            }
            return draft
        }
    }
}
