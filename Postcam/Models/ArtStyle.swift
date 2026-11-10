import CoreGraphics
import Foundation

/// Styles shown in the bottom carousel. Add a case here, a swatch in `StyleSwatch`,
/// and a branch in `CameraController.handleVideo`.
enum ArtStyle: String, CaseIterable, Identifiable {
    case postcard
    case sonnyBoy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .postcard: return "Postcard"
        case .sonnyBoy: return "Sonny Boy"
        }
    }

    var usesStamp: Bool {
        switch self {
        case .postcard: return true
        case .sonnyBoy: return false
        }
    }
}
