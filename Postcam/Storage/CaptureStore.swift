import Combine
import UIKit

/// Postcam's own roll. Files live in Application Support so a reinstall is the only way they disappear,
/// and paths are rebuilt from the current container rather than stored absolute.
final class CaptureStore: ObservableObject {
    @Published private(set) var captures: [CaptureItem] = []
    @Published private(set) var latestThumbnail: UIImage?

    private let root: URL
    private let media: URL
    private let thumbs: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Postcam", isDirectory: true)
        media = root.appendingPathComponent("Media", isDirectory: true)
        thumbs = root.appendingPathComponent("Thumbs", isDirectory: true)
        indexURL = root.appendingPathComponent("captures.json")
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        load()
    }

    func mediaURL(for item: CaptureItem) -> URL {
        let ext = item.kind == .photo ? "jpg" : "mov"
        return media.appendingPathComponent("\(item.id.uuidString).\(ext)")
    }

    func thumbURL(for item: CaptureItem) -> URL {
        thumbs.appendingPathComponent("\(item.id.uuidString).jpg")
    }

    @discardableResult
    func savePhoto(_ image: UIImage, date: Date) throws -> CaptureItem {
        let item = CaptureItem(id: UUID(), kind: .photo, createdAt: date, duration: nil)
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw StoreError.encode
        }
        try data.write(to: mediaURL(for: item), options: .atomic)
        let thumb = thumbnail(from: image)
        if let thumbData = thumb.jpegData(compressionQuality: 0.8) {
            try? thumbData.write(to: thumbURL(for: item), options: .atomic)
        }
        captures.insert(item, at: 0)
        latestThumbnail = thumb
        try persist()
        return item
    }

    @discardableResult
    func saveVideo(from tempURL: URL, thumbnail preview: UIImage, duration: TimeInterval, date: Date) throws -> CaptureItem {
        let item = CaptureItem(id: UUID(), kind: .video, createdAt: date, duration: duration)
        let destination = mediaURL(for: item)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try FileManager.default.copyItem(at: tempURL, to: destination)
            try? FileManager.default.removeItem(at: tempURL)
        }
        // The parameter used to be named `thumbnail`, which hid this method and
        // made `thumbnail(from:)` look like a call on the UIImage.
        let thumb = self.thumbnail(from: preview)
        if let thumbData = thumb.jpegData(compressionQuality: 0.8) {
            try? thumbData.write(to: thumbURL(for: item), options: .atomic)
        }
        captures.insert(item, at: 0)
        latestThumbnail = thumb
        try persist()
        return item
    }

    func delete(_ item: CaptureItem) {
        captures.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: mediaURL(for: item))
        try? FileManager.default.removeItem(at: thumbURL(for: item))
        try? persist()
        refreshLatestThumbnail()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONCoding.decoder().decode([CaptureItem].self, from: data) else {
            return
        }
        captures = decoded
            .filter { FileManager.default.fileExists(atPath: mediaURL(for: $0).path) }
            .sorted { $0.createdAt > $1.createdAt }
        refreshLatestThumbnail()
    }

    private func persist() throws {
        let data = try JSONCoding.encoder().encode(captures)
        try data.write(to: indexURL, options: .atomic)
    }

    private func refreshLatestThumbnail() {
        guard let first = captures.first else {
            latestThumbnail = nil
            return
        }
        latestThumbnail = UIImage(contentsOfFile: thumbURL(for: first).path)
    }

    private func thumbnail(from image: UIImage) -> UIImage {
        let maxSide: CGFloat = 360
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / max(longest, 1))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

enum StoreError: LocalizedError {
    case encode

    var errorDescription: String? {
        switch self {
        case .encode: return "Couldn't encode that image."
        }
    }
}
