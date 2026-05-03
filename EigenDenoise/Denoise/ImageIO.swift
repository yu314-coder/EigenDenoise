//
//  ImageIO.swift
//  Folder loading + PNG saving for grayscale Float images in [0, 1].
//

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

public enum ImageIO: Sendable {

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "bmp", "tif", "tiff", "gif",
    ]

    /// List image files in a folder (non-recursive, alphabetical, image-typed).
    public nonisolated static func listImages(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Load and resize a single image to (H, W) grayscale Float in [0, 1].
    public nonisolated static func loadGray(_ url: URL, H: Int, W: Int) -> [Float]? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: W, height: H)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return rasterize(cg, H: H, W: W)
    }

    /// Load a folder of images at a fixed size. Returns the (n, H, W) flat
    /// array, file names (basename), and the resolved (H, W).
    public nonisolated static func loadFolder(_ folder: URL, H: Int, W: Int) -> (data: [Float], names: [String])? {
        let files = listImages(in: folder)
        guard !files.isEmpty else { return nil }
        var arr = [Float]()
        arr.reserveCapacity(files.count * H * W)
        var names = [String]()
        for f in files {
            guard let pix = loadGray(f, H: H, W: W) else { continue }
            arr.append(contentsOf: pix)
            names.append(f.lastPathComponent)
        }
        return (arr, names)
    }

    /// Resize-and-convert via Core Graphics → grayscale Float in [0, 1].
    private nonisolated static func rasterize(_ cg: CGImage, H: Int, W: Int) -> [Float]? {
        let cs = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = W
        var bytes = [UInt8](repeating: 0, count: H * bytesPerRow)
        guard let ctx = bytes.withUnsafeMutableBufferPointer({ ptr in
            CGContext(data: ptr.baseAddress,
                      width: W, height: H,
                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: cs, bitmapInfo: 0)
        }) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        // CGContext writes top-down; CG image origin is lower-left so we don't flip — values are fine for our purposes (denoise treats images symmetrically).
        var out = [Float](repeating: 0, count: H * W)
        for i in 0..<(H * W) { out[i] = Float(bytes[i]) / 255.0 }
        return out
    }

    /// Save a Float array (H × W, values in [0, 1]) as a grayscale PNG.
    @discardableResult
    public nonisolated static func savePNG(_ data: [Float], H: Int, W: Int, to url: URL) -> Bool {
        precondition(data.count == H * W)
        var bytes = [UInt8](repeating: 0, count: H * W)
        for i in 0..<(H * W) { bytes[i] = UInt8(min(max(data[i], 0), 1) * 255) }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return false }
        guard let cg = CGImage(width: W, height: H, bitsPerComponent: 8,
                                bitsPerPixel: 8, bytesPerRow: W,
                                space: cs, bitmapInfo: [], provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return false }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Convert an (H × W) Float array in [0, 1] into an NSImage for display.
    public nonisolated static func nsImage(_ data: [Float], H: Int, W: Int) -> NSImage? {
        precondition(data.count == H * W)
        var bytes = [UInt8](repeating: 0, count: H * W)
        for i in 0..<(H * W) { bytes[i] = UInt8(min(max(data[i], 0), 1) * 255) }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        guard let cg = CGImage(width: W, height: H, bitsPerComponent: 8,
                                bitsPerPixel: 8, bytesPerRow: W,
                                space: cs, bitmapInfo: [], provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: W, height: H))
    }
}
