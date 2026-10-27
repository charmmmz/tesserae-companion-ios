import OSLog
import Photos

/// Requests access only to retry the current shared item's existing provider.
/// Limited access must include that photo; this never enumerates the library.
@MainActor enum SelectedLivePhotoRecovery {
    static func requestAccess() async throws {
        try Task.checkCancellation()
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        try Task.checkCancellation()
        MediaFrameDiagnostics.logger.notice("livePhoto.recovery.authorization status=\(status.rawValue)")
        guard status == .limited || status == .authorized else {
            throw status == .denied ? MediaFrameError.photoAccessDenied : MediaFrameError.unavailable
        }
    }
}
