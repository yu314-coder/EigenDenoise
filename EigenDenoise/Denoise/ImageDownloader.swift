//
//  ImageDownloader.swift
//  Async batch image downloader. URLSession-only — no subprocess, no
//  third-party deps, sandbox-safe. Each URL is fetched, the response is
//  validated as an image, and the bytes are written into the destination
//  folder with a sensible filename (URL last component, de-conflicted).
//

import AppKit
import Foundation

public struct DownloadProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentURL: String
    public let lastError: String?
}

public actor ImageDownloader {

    public init() {}

    /// Downloads every URL into `destination`. Reports incremental progress
    /// via `progress`. Skips URLs that already exist under the same name.
    /// Returns the count successfully written.
    public func download(_ urls: [URL],
                          to destination: URL,
                          progress: @escaping @Sendable (DownloadProgress) -> Void) async -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var ok = 0
        let total = urls.count
        for (i, src) in urls.enumerated() {
            await reportProgress(progress, completed: ok, total: total,
                                  currentURL: src.absoluteString, error: nil)
            do {
                let dst = uniqueDestination(for: src, in: destination, fm: fm)
                if fm.fileExists(atPath: dst.path) { continue }
                let (data, response) = try await URLSession.shared.data(from: src)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw NSError(domain: "ImageDownloader", code: code,
                                   userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
                }
                guard NSImage(data: data) != nil else {
                    throw NSError(domain: "ImageDownloader", code: 415,
                                   userInfo: [NSLocalizedDescriptionKey: "not a recognised image"])
                }
                try data.write(to: dst, options: .atomic)
                ok += 1
                await reportProgress(progress, completed: ok, total: total,
                                      currentURL: src.absoluteString, error: nil)
            } catch {
                await reportProgress(progress, completed: ok, total: total,
                                      currentURL: src.absoluteString,
                                      error: error.localizedDescription)
                EDLog.warn(.folder, "download fail \(src) — \(error.localizedDescription)")
                _ = i  // silence unused-warning
            }
        }
        return ok
    }

    private func reportProgress(_ cb: @escaping @Sendable (DownloadProgress) -> Void,
                                 completed: Int, total: Int,
                                 currentURL: String, error: String?) async {
        let p = DownloadProgress(completed: completed, total: total,
                                  currentURL: currentURL, lastError: error)
        cb(p)
    }

    /// Build a unique filename inside `destination` from the URL's last path
    /// component. If the file already exists, append "-1", "-2" … before the
    /// extension.
    private func uniqueDestination(for url: URL, in destination: URL,
                                    fm: FileManager) -> URL {
        var name = url.lastPathComponent
        if name.isEmpty || name == "/" {
            name = "image-\(UUID().uuidString.prefix(8)).png"
        }
        // Strip query suffix if any.
        if let q = name.firstIndex(of: "?") { name = String(name[..<q]) }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = destination.appendingPathComponent(name)
        var i = 0
        while fm.fileExists(atPath: candidate.path) {
            i += 1
            let nm = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            candidate = destination.appendingPathComponent(nm)
        }
        return candidate
    }
}
