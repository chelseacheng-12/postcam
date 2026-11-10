import Combine
import SwiftUI
import UIKit

@main
struct PostcamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: model)
        }
    }
}

final class AppModel: ObservableObject {
    let camera: CameraController
    let store: CaptureStore
    let settings: StampSettings
    let compositor: StampCompositor

    @Published var banner: String?
    @Published var isImporting = false

    private var cancellables: Set<AnyCancellable> = []
    private var bannerToken = 0

    init() {
        let settings = StampSettings()
        let store = CaptureStore()
        let compositor = StampCompositor()
        let camera = CameraController(compositor: compositor, settings: settings)
        self.settings = settings
        self.store = store
        self.compositor = compositor
        self.camera = camera

        camera.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                return
            }
            .store(in: &cancellables)
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                return
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                return
            }
            .store(in: &cancellables)

        camera.onPhoto = { [weak self] image in
            DispatchQueue.main.async {
                self?.savePhoto(image)
                return
            }
        }
        camera.onVideo = { [weak self] url, thumbnail, duration in
            DispatchQueue.main.async {
                self?.saveVideo(tempURL: url, thumbnail: thumbnail, duration: duration)
                return
            }
        }
        camera.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.showBanner(text)
                return
            }
        }
    }

    func showBanner(_ text: String) {
        bannerToken += 1
        let token = bannerToken
        banner = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.bannerToken == token else { return }
            self.banner = nil
        }
    }

    func importPhoto(_ data: Data) {
        guard !isImporting else { return }
        isImporting = true
        settings.refreshDate()
        let copy = settings.copyForCurrentFrame()
        DispatchQueue.global(qos: .userInitiated).async { [compositor, weak self] in
            let output: UIImage? = {
                guard let image = UIImage(data: data),
                      let source = ImagePrep.ciImage(from: image, maxPixel: 2800) else { return nil }
                return compositor.uiImage(from: compositor.composite(source, copy: copy))
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImporting = false
                guard let output else {
                    self.showBanner("That photo couldn't be loaded.")
                    return
                }
                self.savePhoto(output)
            }
        }
    }

    private func savePhoto(_ image: UIImage) {
        do {
            let item = try store.savePhoto(image, date: Date())
            let url = store.mediaURL(for: item)
            Task {
                let result = await PhotoLibrarySaver.saveImage(at: url)
                DispatchQueue.main.async {
                    switch result {
                    case .saved:
                        self.showBanner("Saved to your library")
                    case .denied:
                        self.showBanner("Saved in Postcam. Photos access is off.")
                    case .failed:
                        self.showBanner("Saved in Postcam. Couldn't copy it to Photos.")
                    }
                }
            }
        } catch {
            showBanner("Couldn't save that photo.")
        }
    }

    private func saveVideo(tempURL: URL, thumbnail: UIImage, duration: TimeInterval) {
        do {
            let item = try store.saveVideo(from: tempURL, thumbnail: thumbnail, duration: duration, date: Date())
            let url = store.mediaURL(for: item)
            Task {
                let result = await PhotoLibrarySaver.saveVideo(at: url)
                DispatchQueue.main.async {
                    switch result {
                    case .saved:
                        self.showBanner("Saved to your library")
                    case .denied:
                        self.showBanner("Saved in Postcam. Photos access is off.")
                    case .failed:
                        self.showBanner("Saved in Postcam. Couldn't copy it to Photos.")
                    }
                }
            }
        } catch {
            showBanner("Couldn't save that video.")
        }
    }
}
