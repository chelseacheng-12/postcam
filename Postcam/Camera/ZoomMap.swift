import AVFoundation
import CoreGraphics

struct LensChoice: Identifiable, Equatable {
    var displayFactor: CGFloat
    var deviceZoom: CGFloat

    var id: String { String(format: "%.3f", displayFactor) }
}

/// Maps `AVCaptureDevice.videoZoomFactor` to the 0.5× / 1× / 2× labels Apple Camera shows.
/// On a virtual multi-camera, 1× is the wide lens, not the device's minimum zoom.
struct ZoomMap {
    var wideAngleDeviceZoom: CGFloat
    var lenses: [LensChoice]
    var minDeviceZoom: CGFloat
    var maxDeviceZoom: CGFloat

    static let identity = ZoomMap(
        wideAngleDeviceZoom: 1,
        lenses: [LensChoice(displayFactor: 1, deviceZoom: 1)],
        minDeviceZoom: 1,
        maxDeviceZoom: 1
    )

    func display(for deviceZoom: CGFloat) -> CGFloat {
        guard wideAngleDeviceZoom > 0 else { return deviceZoom }
        return deviceZoom / wideAngleDeviceZoom
    }

    func deviceZoom(forDisplay display: CGFloat) -> CGFloat {
        display * wideAngleDeviceZoom
    }

    static func make(for device: AVCaptureDevice) -> ZoomMap {
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = min(device.maxAvailableVideoZoomFactor, 15)
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors
            .map { CGFloat(truncating: $0) }
            .filter { $0.isFinite }
            .sorted()

        let wide = switches.first(where: { $0 > minimum + 0.05 }) ?? minimum
        var lenses: [LensChoice] = []
        if wide > minimum + 0.05 {
            lenses.append(LensChoice(displayFactor: minimum / wide, deviceZoom: minimum))
        }
        lenses.append(LensChoice(displayFactor: 1, deviceZoom: wide))

        if switches.count >= 2, switches[1] > wide + 0.05 {
            let tele = min(switches[1], maximum)
            lenses.append(LensChoice(displayFactor: tele / wide, deviceZoom: tele))
        } else {
            let doubled = min(wide * 2, maximum)
            if doubled > wide * 1.15 {
                lenses.append(LensChoice(displayFactor: doubled / wide, deviceZoom: doubled))
            }
        }

        return ZoomMap(
            wideAngleDeviceZoom: wide,
            lenses: lenses,
            minDeviceZoom: minimum,
            maxDeviceZoom: maximum
        )
    }

    static func format(_ value: CGFloat) -> String {
        guard value.isFinite else { return "1" }
        let tenths = (value * 10).rounded() / 10
        if abs(tenths - tenths.rounded()) < 0.001 {
            return String(format: "%.0f", tenths)
        }
        return String(format: "%.1f", tenths)
    }
}
