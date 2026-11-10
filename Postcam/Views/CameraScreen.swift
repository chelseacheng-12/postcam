import SwiftUI
import UIKit

struct CameraScreen: View {
    @ObservedObject var model: AppModel
    @State private var showAlbum = false
    @State private var showSettings = false

    private var camera: CameraController { model.camera }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreviewRepresentable(camera: camera)
                .ignoresSafeArea()

            if camera.screenFlash {
                Color.white.ignoresSafeArea()
            }
            Color.white
                .opacity(camera.shutterBlink ? 0.9 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.18), value: camera.shutterBlink)

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                Color.clear
                    .allowsHitTesting(false)
                if let banner = model.banner {
                    bannerPill(banner)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
                bottomCluster
                    .padding(.bottom, 8)
            }

            if camera.authorization == .denied || camera.authorization == .restricted {
                PermissionView()
                    .ignoresSafeArea()
            } else if let reason = camera.unavailableReason {
                UnavailableView(message: reason)
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            camera.stop()
        }
        .fullScreenCover(isPresented: $showAlbum, onDismiss: {
            camera.start()
        }) {
            AlbumView(model: model)
                .onAppear { camera.stop() }
        }
        .sheet(isPresented: $showSettings) {
            StampSettingsView(settings: model.settings, compositor: model.compositor)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var topBar: some View {
        ZStack {
            HStack {
                flashButton
                Spacer()
                settingsButton
            }
            if camera.isRecording {
                recordingBadge
            }
        }
        .padding(.horizontal, 12)
    }

    private var flashButton: some View {
        Button {
            Haptic.select()
            camera.toggleFlash()
        } label: {
            Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(camera.flashEnabled ? PostcamColor.cameraYellow : .white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.flashAvailable)
        .opacity(camera.flashAvailable ? 1 : 0.35)
        .accessibilityLabel(camera.flashEnabled ? "Flash on" : "Flash off")
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stamp text")
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0)
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(PostcamColor.recordRed)
                .frame(width: 8, height: 8)
            Text(DurationFormat.live(camera.recordingDuration))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.45), in: Capsule())
        .accessibilityLabel("Recording \(DurationFormat.live(camera.recordingDuration))")
    }

    private var bottomCluster: some View {
        VStack(spacing: 16) {
            ZoomControls(camera: camera)
            modeSelector
            HStack {
                albumButton
                    .frame(width: 64)
                Spacer()
                ShutterButton(mode: camera.mode, isRecording: camera.isRecording) {
                    shutterTapped()
                }
                Spacer()
                flipButton
                    .frame(width: 64)
            }
        }
        .padding(.horizontal, 22)
    }

    private var modeSelector: some View {
        HStack(spacing: 28) {
            modeButton(.video)
            modeButton(.photo)
        }
        .opacity(camera.isRecording ? 0.4 : 1)
        .allowsHitTesting(!camera.isRecording)
        .simultaneousGesture(modeSwipe)
        .accessibilityElement(children: .contain)
    }

    private var modeSwipe: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard !camera.isRecording else { return }
                if value.translation.width <= -24 {
                    selectMode(.photo)
                    return
                }
                if value.translation.width >= 24 {
                    selectMode(.video)
                    return
                }
                return
            }
    }

    private func modeButton(_ mode: CaptureMode) -> some View {
        Button {
            selectMode(mode)
        } label: {
            Text(mode.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(camera.mode == mode ? PostcamColor.modePinkColor : Color.white.opacity(0.72))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 0)
                .frame(minWidth: 64, minHeight: 32)
                .animation(.easeInOut(duration: 0.2), value: camera.mode)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(camera.mode == mode ? .isSelected : [])
    }

    private func selectMode(_ mode: CaptureMode) {
        guard camera.mode != mode else { return }
        Haptic.select()
        camera.setMode(mode)
    }

    private var albumButton: some View {
        Button {
            showAlbum = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                if let image = model.store.latestThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Album")
    }

    private var flipButton: some View {
        Button {
            Haptic.select()
            camera.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.4 : 1)
        .accessibilityLabel("Switch camera")
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0)
    }

    private func bannerPill(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 24)
    }

    private func shutterTapped() {
        switch camera.mode {
        case .photo:
            Haptic.shutter()
            camera.takePhoto()
        case .video:
            Haptic.record()
            camera.toggleRecording()
        }
    }
}
