import SwiftUI

struct ZoomControls: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        lensPills
            .overlay(alignment: .top) {
                Text(ZoomMap.format(camera.zoomDisplay) + "×")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .offset(y: -34)
                    .allowsHitTesting(false)
            }
    }

    private var lensPills: some View {
        HStack(spacing: 0) {
            ForEach(camera.lenses) { lens in
                Button {
                    Haptic.select()
                    camera.selectLens(lens)
                } label: {
                    Text(title(for: lens))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(camera.isLensActive(lens) ? PostcamColor.cameraYellow : .white)
                        .frame(minWidth: 44, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(ZoomMap.format(lens.displayFactor)) times")
            }
        }
        .padding(.horizontal, 4)
        .background(Color.black.opacity(0.45), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }

    /// Pills stay on the lens they represent. The live factor, such as 1.8×, is the overlay above.
    private func title(for lens: LensChoice) -> String {
        let value = ZoomMap.format(lens.displayFactor)
        return camera.isLensActive(lens) ? value + "×" : value
    }
}
