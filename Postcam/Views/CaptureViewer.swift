import AVKit
import SwiftUI
import UIKit

struct CaptureViewer: View {
    @ObservedObject var store: CaptureStore
    @Binding var selection: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: UUID
    @State private var confirmDelete = false
    @State private var shareItem: SharePayload?

    init(store: CaptureStore, selection: Binding<UUID?>) {
        self.store = store
        _selection = selection
        _currentID = State(initialValue: selection.wrappedValue ?? UUID())
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentID) {
                ForEach(store.captures) { item in
                    page(item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            HStack(spacing: 18) {
                viewerButton("xmark", label: "Close") { dismiss() }
                Spacer()
                viewerButton("square.and.arrow.up", label: "Share") { shareCurrent() }
                viewerButton("trash", label: "Delete") { confirmDelete = true }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear { AudioRoute.playback() }
        .onDisappear { AudioRoute.capture() }
        .confirmationDialog("Delete this capture?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $shareItem) { payload in
            ActivitySheet(items: [payload.url])
        }
    }

    @ViewBuilder
    private func page(_ item: CaptureItem) -> some View {
        switch item.kind {
        case .photo:
            PhotoPage(url: store.mediaURL(for: item))
        case .video:
            VideoPage(url: store.mediaURL(for: item), active: item.id == currentID)
        }
    }

    private func viewerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func shareCurrent() {
        guard let item = store.captures.first(where: { $0.id == currentID }) else { return }
        shareItem = SharePayload(url: store.mediaURL(for: item))
    }

    private func deleteCurrent() {
        guard let index = store.captures.firstIndex(where: { $0.id == currentID }) else { return }
        let item = store.captures[index]
        store.delete(item)
        if store.captures.isEmpty {
            selection = nil
            dismiss()
            return
        }
        let next = min(index, store.captures.count - 1)
        let id = store.captures[next].id
        currentID = id
        selection = id
    }
}

private struct PhotoPage: View {
    var url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomablePhoto(image: image)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task {
            let path = url.path
            let loaded = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)
            }.value
            image = loaded
        }
    }
}

private struct VideoPage: View {
    var url: URL
    var active: Bool
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.black
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: active) { _, isActive in
            if isActive {
                player?.play()
            } else {
                player?.pause()
            }
            return
        }
        .onDisappear {
            player?.pause()
            return
        }
    }

    private func prepare() {
        guard player == nil else { return }
        let next = AVPlayer(url: url)
        player = next
        if active { next.play() }
    }
}

private struct ZoomablePhoto: UIViewRepresentable {
    var image: UIImage

    func makeUIView(context: Context) -> ZoomPhotoView {
        ZoomPhotoView(image: image)
    }

    func updateUIView(_ view: ZoomPhotoView, context: Context) {
        view.setImage(image)
    }
}

private final class ZoomPhotoView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    func setImage(_ image: UIImage) {
        guard imageView.image == nil else { return }
        imageView.image = image
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        if zoomScale <= 1.001 {
            fit()
        } else {
            centerImage()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func fit() {
        guard let image = imageView.image else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerImage()
    }

    private func centerImage() {
        let extraX = max(0, (bounds.width - contentSize.width) * 0.5)
        let extraY = max(0, (bounds.height - contentSize.height) * 0.5)
        imageView.center = CGPoint(x: contentSize.width * 0.5 + extraX, y: contentSize.height * 0.5 + extraY)
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivitySheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = controller.view
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
