import CoreGraphics

struct StampLayout {
    /// Outer rectangle of the perforation teeth. Notches are cut inside this rect.
    var bounds: CGRect
    /// Illustration window. Everything in here is stylized; the ring around it is paper.
    var window: CGRect
    var path: CGPath
}

enum StampGeometry {
    static let widthOverHeight: CGFloat = 0.78
    /// Keeps a large stamp on screen without letting the scallops leave the frame.
    static let maxHeightFraction: CGFloat = 0.78
    static let maxWidthFraction: CGFloat = 0.92

    static func layout(in extent: CGRect, widthFraction: CGFloat) -> StampLayout {
        let fraction = min(max(widthFraction, 0.45), maxWidthFraction)
        var width = extent.width * fraction
        var height = width / widthOverHeight
        let maxHeight = extent.height * maxHeightFraction
        let maxWidth = extent.width * maxWidthFraction
        if height > maxHeight {
            height = maxHeight
            width = height * widthOverHeight
        }
        if width > maxWidth {
            width = maxWidth
            height = width / widthOverHeight
        }

        let bounds = CGRect(
            x: extent.midX - width / 2,
            y: extent.midY - height / 2,
            width: width,
            height: height
        )
        let columns = max(10, Int((bounds.width / 34).rounded()))
        let rows = max(12, Int((bounds.height / 34).rounded()))
        let radii = scallopRadii(bounds: bounds, columns: columns, rows: rows)
        let path = scallopedPath(bounds: bounds, columns: columns, rows: rows, rx: radii.rx, ry: radii.ry)
        // Notches bite inward by one radius. The window sits further in so the drawing
        // stays on the paper, clear of the perforations.
        let margin = max(radii.rx, radii.ry) * 2.15
        let window = bounds.insetBy(dx: margin, dy: margin)
        return StampLayout(bounds: bounds, window: window, path: path)
    }

    static func scallopRadii(bounds: CGRect, columns: Int, rows: Int) -> (rx: CGFloat, ry: CGFloat) {
        let rx = bounds.width / CGFloat(2 * max(columns, 1))
        let ry = bounds.height / CGFloat(2 * max(rows, 1))
        return (rx, ry)
    }

    /// Closed postage-stamp outline in Core Graphics y-up space.
    /// Semicircles are notches cut into the paper on every side. The outer teeth sit on `bounds`,
    /// and each arc is the inward half so top, right, bottom, and left all match.
    static func scallopedPath(
        bounds: CGRect,
        columns: Int,
        rows: Int,
        rx: CGFloat,
        ry: CGFloat
    ) -> CGPath {
        let stepX = bounds.width / CGFloat(columns)
        let stepY = bounds.height / CGFloat(rows)
        let path = CGMutablePath()

        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        // Bottom, left to right. Clockwise through +Y, into the stamp.
        for index in 0..<columns {
            let centerX = bounds.minX + (CGFloat(index) + 0.5) * stepX
            path.addArc(
                center: CGPoint(x: centerX, y: bounds.minY),
                radius: rx,
                startAngle: .pi,
                endAngle: 0,
                clockwise: true
            )
        }
        // Right, bottom to top. Clockwise through -X, into the stamp.
        for index in 0..<rows {
            let centerY = bounds.minY + (CGFloat(index) + 0.5) * stepY
            path.addArc(
                center: CGPoint(x: bounds.maxX, y: centerY),
                radius: ry,
                startAngle: -.pi / 2,
                endAngle: .pi / 2,
                clockwise: true
            )
        }
        // Top, right to left. Clockwise through -Y, into the stamp.
        for index in 0..<columns {
            let centerX = bounds.maxX - (CGFloat(index) + 0.5) * stepX
            path.addArc(
                center: CGPoint(x: centerX, y: bounds.maxY),
                radius: rx,
                startAngle: 0,
                endAngle: .pi,
                clockwise: true
            )
        }
        // Left, top to bottom. Clockwise through +X, into the stamp.
        for index in 0..<rows {
            let centerY = bounds.maxY - (CGFloat(index) + 0.5) * stepY
            path.addArc(
                center: CGPoint(x: bounds.minX, y: centerY),
                radius: ry,
                startAngle: .pi / 2,
                endAngle: -.pi / 2,
                clockwise: true
            )
        }
        path.closeSubpath()
        return path
    }
}
