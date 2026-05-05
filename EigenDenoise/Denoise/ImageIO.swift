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
        "png", "jpg", "jpeg", "bmp", "tif", "tiff", "gif", "pgm", "ppm", "pbm",
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
    /// Falls back to a manual PGM/PPM/PBM parser for Netpbm formats (ORL faces),
    /// which NSImage does not handle on macOS.
    public nonisolated static func loadGray(_ url: URL, H: Int, W: Int) -> [Float]? {
        let ext = url.pathExtension.lowercased()
        if ext == "pgm" || ext == "ppm" || ext == "pbm" {
            if let cg = loadNetpbm(url) {
                return rasterize(cg, H: H, W: W)
            }
            // fall through to NSImage as a last resort
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: W, height: H)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return rasterize(cg, H: H, W: W)
    }

    /// Minimal Netpbm (P2/P5 PGM, P3/P6 PPM, P1/P4 PBM) decoder → CGImage.
    /// Handles ASCII and binary variants, comments, and 8-bit / 16-bit depth.
    private nonisolated static func loadNetpbm(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), data.count > 3 else { return nil }
        let bytes = [UInt8](data)
        // Read magic.
        guard bytes[0] == 0x50 /* 'P' */ else { return nil }
        let magic = bytes[1]
        var i = 2
        // Skip whitespace + comments to grab header tokens.
        func nextToken() -> String? {
            // Skip whitespace and #-comments
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x23 { // '#'
                    while i < bytes.count, bytes[i] != 0x0A { i += 1 }
                    continue
                }
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
                break
            }
            let start = i
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { break }
                i += 1
            }
            guard start < i else { return nil }
            return String(bytes: bytes[start..<i], encoding: .ascii)
        }
        guard let wStr = nextToken(), let W = Int(wStr),
              let hStr = nextToken(), let H = Int(hStr) else { return nil }
        var maxVal = 1
        let isPBM = (magic == 0x31 || magic == 0x34) // P1/P4
        if !isPBM {
            guard let mvStr = nextToken(), let mv = Int(mvStr) else { return nil }
            maxVal = max(mv, 1)
        }
        // Single whitespace separator before binary data (for P4/P5/P6).
        if magic == 0x34 || magic == 0x35 || magic == 0x36 {
            if i < bytes.count { i += 1 }
        }
        // Decode pixels into 8-bit grayscale.
        var gray = [UInt8](repeating: 0, count: H * W)
        let isAscii = (magic == 0x31 || magic == 0x32 || magic == 0x33)
        let scale = 255.0 / Double(maxVal)
        if isAscii {
            // Tokenized ints
            var k = 0
            let total = (magic == 0x33) ? H * W * 3 : H * W
            var vals = [Int](); vals.reserveCapacity(total)
            while vals.count < total, let t = nextToken(), let v = Int(t) {
                vals.append(v)
                _ = k
            }
            if magic == 0x33 { // ASCII PPM
                for p in 0..<(H * W) {
                    let r = Double(vals[3*p]), g = Double(vals[3*p+1]), b = Double(vals[3*p+2])
                    let y = 0.2989 * r + 0.5870 * g + 0.1140 * b
                    gray[p] = UInt8(min(max(y * scale, 0), 255))
                }
            } else { // P1 (PBM) or P2 (PGM)
                for p in 0..<(H * W) {
                    let v = vals[p]
                    if magic == 0x31 { gray[p] = (v == 0) ? 255 : 0 } // PBM: 1=black
                    else { gray[p] = UInt8(min(max(Double(v) * scale, 0), 255)) }
                }
            }
        } else {
            // Binary
            switch magic {
            case 0x34: // P4 PBM, 1-bit packed
                let rowBytes = (W + 7) / 8
                for y in 0..<H {
                    for x in 0..<W {
                        let off = i + y * rowBytes + (x / 8)
                        if off >= bytes.count { return nil }
                        let bit = (bytes[off] >> (7 - (x % 8))) & 1
                        gray[y * W + x] = (bit == 1) ? 0 : 255
                    }
                }
            case 0x35: // P5 PGM
                if maxVal < 256 {
                    guard i + H * W <= bytes.count else { return nil }
                    if maxVal == 255 {
                        for p in 0..<(H * W) { gray[p] = bytes[i + p] }
                    } else {
                        for p in 0..<(H * W) {
                            gray[p] = UInt8(min(max(Double(bytes[i + p]) * scale, 0), 255))
                        }
                    }
                } else {
                    guard i + H * W * 2 <= bytes.count else { return nil }
                    for p in 0..<(H * W) {
                        let v = (Int(bytes[i + 2*p]) << 8) | Int(bytes[i + 2*p + 1])
                        gray[p] = UInt8(min(max(Double(v) * scale, 0), 255))
                    }
                }
            case 0x36: // P6 PPM
                let bpc = (maxVal < 256) ? 1 : 2
                let stride = 3 * bpc
                guard i + H * W * stride <= bytes.count else { return nil }
                for p in 0..<(H * W) {
                    let r: Int, g: Int, b: Int
                    if bpc == 1 {
                        r = Int(bytes[i + 3*p])
                        g = Int(bytes[i + 3*p + 1])
                        b = Int(bytes[i + 3*p + 2])
                    } else {
                        r = (Int(bytes[i + 6*p])     << 8) | Int(bytes[i + 6*p + 1])
                        g = (Int(bytes[i + 6*p + 2]) << 8) | Int(bytes[i + 6*p + 3])
                        b = (Int(bytes[i + 6*p + 4]) << 8) | Int(bytes[i + 6*p + 5])
                    }
                    let y = 0.2989 * Double(r) + 0.5870 * Double(g) + 0.1140 * Double(b)
                    gray[p] = UInt8(min(max(y * scale, 0), 255))
                }
            default:
                return nil
            }
        }
        // Build a CGImage from the gray buffer.
        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: W, space: cs, bitmapInfo: [],
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
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
