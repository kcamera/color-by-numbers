import CoreGraphics
import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A decoded bitmap in plain sRGB bytes — the pipeline's working currency.
/// Deliberately a dumb value type: all pipeline stages are pure functions
/// over these buffers, which is what keeps them unit-testable on any
/// platform.
public struct RasterImage: Sendable {
    public var width: Int
    public var height: Int
    /// Row-major RGBA, 4 bytes per pixel, sRGB, alpha last.
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "buffer size must match dimensions")
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    @inlinable
    public func pixelOffset(x: Int, y: Int) -> Int { (y * width + x) * 4 }
}

public enum RasterImageError: Error, CustomStringConvertible {
    case unreadable(URL)
    case undrawable
    case unwritable(URL)

    public var description: String {
        switch self {
        case .unreadable(let url): "could not decode an image from \(url.path)"
        case .undrawable: "could not create a drawing context for the image"
        case .unwritable(let url): "could not write PNG to \(url.path)"
        }
    }
}

extension RasterImage {
    /// Decodes any ImageIO-supported file (PNG, JPEG, HEIC…) into sRGB RGBA.
    public static func load(from url: URL) throws -> RasterImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RasterImageError.unreadable(url)
        }
        return try RasterImage(cgImage: cgImage)
    }

    /// Renders a CGImage into the canonical sRGB/RGBA byte layout, whatever
    /// its original color space or pixel format was.
    public init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // White backing so transparent source pixels become paper, not
            // black — scans and stickers with alpha import sensibly.
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw RasterImageError.undrawable }

        self.init(width: width, height: height, rgba: rgba)
    }

    public func makeCGImage() -> CGImage? {
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil
            )
        else { throw RasterImageError.unwritable(url) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RasterImageError.unwritable(url)
        }
    }
}
