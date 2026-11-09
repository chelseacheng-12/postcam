import Photos

enum LibrarySaveResult {
    case saved
    case denied
    case failed
}

enum PhotoLibrarySaver {
    static func saveImage(at url: URL) async -> LibrarySaveResult {
        await save {
            _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }

    static func saveVideo(at url: URL) async -> LibrarySaveResult {
        await save {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private static func save(_ changes: @escaping () -> Void) async -> LibrarySaveResult {
        let status = await authorize()
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges(changes)
            return .saved
        } catch {
            return .failed
        }
    }

    private static func authorize() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return current
    }
}
