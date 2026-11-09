import SwiftUI

struct ShutterButton: View {
    var mode: CaptureMode
    var isRecording: Bool
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                inner
            }
            .frame(width: 82, height: 82)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: isRecording)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: mode)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var inner: some View {
        if mode == .video && isRecording {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(PostcamColor.recordRed)
                .frame(width: 28, height: 28)
        } else if mode == .video {
            Circle()
                .fill(PostcamColor.recordRed)
                .frame(width: 58, height: 58)
        } else {
            Circle()
                .fill(.white)
                .frame(width: 60, height: 60)
        }
    }

    private var label: String {
        if mode == .video {
            return isRecording ? "Stop recording" : "Start recording"
        }
        return "Take photo"
    }
}

struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
