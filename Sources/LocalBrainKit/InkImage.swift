//
//  InkImage.swift
//  LocalBrainKit
//
//  Pixel work for the "ink in" feature, with CoreGraphics and ImageIO only (no
//  AppKit, so it runs in the harness and in tests):
//    - compositeInk: draw the user's trail onto the screenshot that goes to the
//      vision model, so the model sees the ink where the user drew it.
//    - cropAround: cut a zoomed image around the ink, with context, so a small
//      circle still shows what it surrounds.
//
//  Everything is in screenshot pixel coordinates with a top-left origin.
//

import CoreGraphics
import Foundation
import ImageIO

/// One pass of a stroke: a colour and a width. Colours are sRGB, 0...1.
public struct InkStrokeLayer: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    /// Line width in image pixels.
    public var width: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1, width: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.width = width
    }
}

/// How ink is drawn: stroke layers painted bottom to top, all with round caps
/// and joins. A casing plus a core is two layers (wide dark or light first,
/// narrow bright second); a plain line is one.
public struct InkStyle: Equatable, Sendable {
    public var layers: [InkStrokeLayer]

    public init(layers: [InkStrokeLayer]) {
        self.layers = layers
    }

    /// The same style with every layer scaled up so the core (the last layer,
    /// painted on top) is at least `minimumCoreWidth` wide. The casings grow by
    /// the same factor, so the look is kept. A style whose core is already wide
    /// enough, or has no usable core, comes back unchanged.
    public func withMinimumCoreWidth(_ minimumCoreWidth: Double) -> InkStyle {
        guard let core = layers.last?.width, core > 0, core < minimumCoreWidth else { return self }
        let factor = minimumCoreWidth / core
        var widened = self
        for index in widened.layers.indices { widened.layers[index].width *= factor }
        return widened
    }
}

public struct InkCrop: Equatable, Sendable {
    public let jpegData: Data
    /// The region of the source image that was cut out, integral, in source pixels.
    public let rectInImagePixels: CGRect
    /// Pixel size of the returned JPEG (smaller than the rect when scaled down).
    public let outputSize: CGSize
}

public enum InkImage {
    public static let jpegQuality: Double = 0.8

    // MARK: - Composite

    /// Draws `strokesInImagePixels` (each an ordered list of points, top-left
    /// origin) onto the JPEG and returns a new JPEG of the same pixel size at
    /// quality 0.8, or nil if the data cannot be decoded or encoded. Layers are
    /// painted across all strokes, bottom layer first, so one stroke's casing
    /// never covers another stroke's core. A one-point stroke draws a dot.
    public static func compositeInk(jpegData: Data,
                                    strokesInImagePixels: [[CGPoint]],
                                    style: InkStyle) -> Data? {
        guard let image = decode(jpegData) else { return nil }
        let width = image.width, height = image.height
        guard let context = makeContext(width: width, height: height) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip to a top-left origin for the strokes only.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for layer in style.layers where layer.width > 0 {
            context.setStrokeColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           components: [layer.red, layer.green, layer.blue, layer.alpha].map { CGFloat($0) })!)
            context.setLineWidth(CGFloat(layer.width))
            for stroke in strokesInImagePixels where !stroke.isEmpty {
                context.beginPath()
                context.move(to: stroke[0])
                if stroke.count == 1 {
                    context.addLine(to: stroke[0])
                } else {
                    for point in stroke.dropFirst() { context.addLine(to: point) }
                }
                context.strokePath()
            }
        }
        guard let result = context.makeImage() else { return nil }
        return encodeJPEG(result)
    }

    // MARK: - Crop

    /// The crop rectangle, without touching any pixels. The ink box grows by
    /// `padding` (a fraction of its own width and height, on every side), then
    /// to at least `minSide` in both directions around the same centre, then
    /// is shifted back inside the image (keeping its size), and finally clamped
    /// to the image if it is larger than the image. Rounded outward to whole
    /// pixels.
    public static func cropRect(forInkBounds bounds: CGRect,
                                imageSize: CGSize,
                                padding: CGFloat = 0.2,
                                minSide: CGFloat = 320) -> CGRect {
        let imageRect = CGRect(origin: .zero, size: imageSize)
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        var width = bounds.width * (1 + 2 * padding)
        var height = bounds.height * (1 + 2 * padding)
        width = min(max(width, minSide), imageSize.width)
        height = min(max(height, minSide), imageSize.height)

        var originX = bounds.midX - width / 2
        var originY = bounds.midY - height / 2
        originX = max(0, min(originX, imageSize.width - width))
        originY = max(0, min(originY, imageSize.height - height))

        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        return rect.integral.intersection(imageRect)
    }

    /// Crops the JPEG around `rectInImagePixels` (the ink bounding box) with
    /// `cropRect` and, if the longer side exceeds `maxLongEdge`, scales it down
    /// to that. Returns nil if the data cannot be decoded or encoded.
    public static func cropAround(jpegData: Data,
                                  rectInImagePixels: CGRect,
                                  padding: CGFloat = 0.2,
                                  minSide: CGFloat = 320,
                                  maxLongEdge: CGFloat = 768) -> InkCrop? {
        guard let image = decode(jpegData) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let rect = cropRect(forInkBounds: rectInImagePixels, imageSize: size,
                            padding: padding, minSide: minSide)
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else { return nil }

        let longEdge = max(rect.width, rect.height)
        var output = cropped
        if maxLongEdge > 0, longEdge > maxLongEdge {
            let scale = maxLongEdge / longEdge
            let scaledWidth = max(1, Int((rect.width * scale).rounded()))
            let scaledHeight = max(1, Int((rect.height * scale).rounded()))
            guard let context = makeContext(width: scaledWidth, height: scaledHeight) else { return nil }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
            guard let scaled = context.makeImage() else { return nil }
            output = scaled
        }
        guard let data = encodeJPEG(output) else { return nil }
        return InkCrop(jpegData: data, rectInImagePixels: rect,
                       outputSize: CGSize(width: output.width, height: output.height))
    }

    // MARK: - ImageIO plumbing

    private static func decode(_ jpegData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
