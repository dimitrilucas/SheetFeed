import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading and writing the working copies of pages kept on disk while a document is being assembled.
public enum ImageFiles {
    public static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A downscaled copy no larger than `maxPixels` on its longest side.
    public static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Lossless (LZW-compressed TIFF), so later exports lose nothing.
    public static func writeLossless(_ image: CGImage, dpi: Double, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw ExportError.couldNotCreate(url.lastPathComponent)
        }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],
        ]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.couldNotCreate(url.lastPathComponent) }
    }
}
