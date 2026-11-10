import SwiftUI

struct StyleCarousel: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(ArtStyle.allCases) { style in
                    Button {
                        Haptic.select()
                        camera.setArtStyle(style)
                    } label: {
                        VStack(spacing: 4) {
                            StyleSwatch(style: style)
                                .frame(width: 56, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(
                                            camera.artStyle == style ? PostcamColor.cameraYellow : Color.white.opacity(0.35),
                                            lineWidth: camera.artStyle == style ? 2 : 1
                                        )
                                }
                            Text(style.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(camera.artStyle == style ? PostcamColor.cameraYellow : Color.white.opacity(0.78))
                                .lineLimit(1)
                        }
                        .frame(minWidth: 72)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(camera.artStyle == style ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 58)
    }
}

/// Static stand-ins. A new style adds a branch here and a case on `ArtStyle`.
struct StyleSwatch: View {
    var style: ArtStyle

    var body: some View {
        switch style {
        case .postcard:
            ZStack {
                Color(red: 0.93, green: 0.78, blue: 0.72)
                VStack(spacing: 2) {
                    Rectangle().fill(Color(red: 0.86, green: 0.32, blue: 0.22)).frame(height: 8)
                    Rectangle().fill(Color(red: 0.95, green: 0.78, blue: 0.28)).frame(width: 22, height: 3)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.white, lineWidth: 3)
                    .padding(2)
            }
        case .sonnyBoy:
            ZStack(alignment: .bottom) {
                Color(red: 0.45, green: 0.78, blue: 0.96)
                Rectangle()
                    .fill(Color(red: 0.98, green: 0.82, blue: 0.28))
                    .frame(height: 12)
                Rectangle()
                    .fill(Color(red: 0.16, green: 0.45, blue: 0.86))
                    .frame(width: 14, height: 18)
                    .offset(x: -10, y: -6)
            }
        }
    }
}
