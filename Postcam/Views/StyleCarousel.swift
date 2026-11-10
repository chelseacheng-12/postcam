import SwiftUI

/// Snapping strip of art styles. The centered item is the selection, so a swipe selects
/// and a tap scrolls the tapped style to the center.
struct StyleCarousel: View {
    @ObservedObject var camera: CameraController
    @State private var centered: ArtStyle?

    private let itemWidth: CGFloat = 76
    private let spacing: CGFloat = 10

    init(camera: CameraController) {
        self.camera = camera
        _centered = State(initialValue: camera.artStyle)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(ArtStyle.allCases) { style in
                        item(style)
                            .frame(width: itemWidth)
                            .id(style)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max(0, (proxy.size.width - itemWidth) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centered)
        }
        .frame(height: 60)
        .opacity(camera.isRecording ? 0.4 : 1)
        .allowsHitTesting(!camera.isRecording)
        .onChange(of: centered) { _, newValue in
            guard let newValue, newValue != camera.artStyle else { return }
            Haptic.select()
            camera.setArtStyle(newValue)
        }
        .onChange(of: camera.artStyle) { _, newValue in
            guard centered != newValue else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                centered = newValue
            }
        }
    }

    private func item(_ style: ArtStyle) -> some View {
        let selected = camera.artStyle == style
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                centered = style
            }
        } label: {
            VStack(spacing: 4) {
                StyleSwatch(style: style)
                    .frame(width: 56, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                selected ? PostcamColor.cameraYellow : Color.white.opacity(0.35),
                                lineWidth: selected ? 2 : 1
                            )
                    }
                Text(style.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? PostcamColor.cameraYellow : Color.white.opacity(0.78))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: itemWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
