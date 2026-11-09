import CoreGraphics

struct StampLayout {
    /// Bounding box of the scalloped paper, including the bumps.
    var bounds: CGRect
    /// Illustration window. Everything in here is stylized; the ring around it is paper.
    var window: CGRect
    var path: CGPath
}

enum StampGeometry {
    static let widthFraction: CGFloat = 0.55
    static let widthOverHeight: CGFloat = 0.78
    static let maxHeightFraction: CGFloat = 0.50

    static func layout(in extent: CGRect) -> StampLayout {
        var width = extent.width * widthFraction
        var height = width / widthOverHeight
        let maxHeight = extent.height * maxHeightFraction
        if height > maxHeight {
            height = maxHeight
            width = height * widthOverHeight
        }
        width = min(width, extent.width * 0.88)
        height = min(height, extent.height * 0.70)

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
        // The centerline sits one radius in from `bounds`. A further inset leaves a paper margin
        // about as thick as a perforation, which is the white border around the drawing.
        let border = max(radii.rx, radii.ry) * 0.9
        let window = bounds.insetBy(dx: radii.rx + border, dy: radii.ry + border)
        return StampLayout(bounds: bounds, window: window, path: path)
    }

    static func scallopRadii(bounds: CGRect, columns: Int, rows: Int) -> (rx: CGFloat, ry: CGFloat) {
        let rx = bounds.width / CGFloat(2 * (columns + 1))
        let ry = bounds.height / CGFloat(2 * (rows + 1))
        return (rx, ry)
    }

    /// Closed scalloped outline. Core Graphics y-up: bumps extend outward from the inset centerline
    /// and land on `bounds`. Semicircles meet edge to edge.
    static func scallopedPath(
        bounds: CGRect,
        columns: Int,
        rows: Int,
        rx: CGFloat,
        ry: CGFloat
    ) -> CGPath {
        let inset = bounds.insetBy(dx: rx, dy: ry)
        let stepX = inset.width / CGFloat(columns)
        let stepY = inset.height / CGFloat(rows)
        let path = CGMutablePath()

        path.move(to: CGPoint(x: inset.minX, y: inset.minY))
        for index in 0..<columns {
            let centerX = inset.minX + (CGFloat(index) + 0.5) * stepX
            path.addArc(
                center: CGPoint(x: centerX, y: inset.minY),
                radius: rx,
                startAngle: .pi,
                endAngle: 0,
                clockwise: true
            )
        }
        for index in 0..<rows {
            let centerY = inset.minY + (CGFloat(index) + 0.5) * stepY
            path.addArc(
                center: CGPoint(x: inset.maxX, y: centerY),
                radius: ry,
                startAngle: -.pi / 2,
                endAngle: .pi / 2,
                clockwise: false
            )
        }
        for index in 0..<columns {
            let centerX = inset.maxX - (CGFloat(index) + 0.5) * stepX
            path.addArc(
                center: CGPoint(x: centerX, y: inset.maxY),
                radius: rx,
                startAngle: 0,
                endAngle: .pi,
                clockwise: false
            )
        }
        for index in 0..<rows {
            let centerY = inset.maxY - (CGFloat(index) + 0.5) * stepY
            path.addArc(
                center: CGPoint(x: inset.minX, y: centerY),
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
