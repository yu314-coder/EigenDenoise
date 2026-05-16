//
//  AppModel.swift
//  Shared application state — folder of loaded images, run parameters,
//  most recent denoise result. The real-image denoise path goes through
//  the rmt-denoise PyPI lib via `RMTDenoiseBridge`; the math UI tabs are
//  fully native Swift.
//

import AppKit
import Foundation
import UniformTypeIdentifiers
import Observation

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    // ---- folder / images ------------------------------------------------
    var folderURL: URL?
    var imageNames: [String] = []
    var imageData: [Float] = []        // (n, H, W) flat
    var imageH: Int = 100
    var imageW: Int = 100
    var imageCount: Int { imageH > 0 && imageW > 0 ? imageData.count / (imageH * imageW) : 0 }

    // ---- run params -----------------------------------------------------
    var testFilename: String = ""
    var nTrain: Int = 100
    var resizeH: Int = 100
    var resizeW: Int = 100

    var noiseConfig: NoiseConfig = NoiseConfig()
    var noiseSeed: UInt64 = 42

    var denoiseConfig: DenoiseConfig = DenoiseConfig()
    var device: String = "auto"        // "auto" | "cpu" | "mps"
    var runMethod: DenoiseRunMethod = .both
    // Post-processing toggles forwarded to the rmt-denoise lib (≥ 2.3.0).
    var applyT: Bool = true            // diagonal T(a, β)
    var colorResize: Bool = true       // (x − min)/max normalisation
    var center: Bool = true            // X̃ = X − X̄ before SVD

    // ---- log ------------------------------------------------------------
    private(set) var logLines: [String] = []
    func log(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(8)
        logLines.append("\(stamp) \(s)")
        if logLines.count > 1500 { logLines.removeFirst(logLines.count - 1500) }
        EDLog.log(.model, s)
    }
    func clearLog() { logLines.removeAll() }

    // ---- results --------------------------------------------------------
    /// Native Swift result (Classical MP, Generalized MP, oracle in-process).
    var lastNativeResult: DenoiseResult?
    /// Result from the rmt-denoise PyPI lib via Python bridge (real pics).
    var lastBridgeResult: RMTBridgeResult?
    /// PNGs the bridge wrote — cached as NSImage for the result grid.
    var bridgeCleanImage: NSImage?
    var bridgeNoisyImage: NSImage?
    var bridgeMPImage: NSImage?
    var bridgeGenImage: NSImage?
    var bridgeResidualImage: NSImage?
    var bridgeOutputDir: URL?

    var lastCleanTest: [Float] = []
    var lastNoisyTest: [Float] = []
    var isDenoising: Bool = false
    /// Live progress while the denoise pipeline runs.
    var denoiseProgress: (fraction: Double, stage: String) = (0, "")
    /// Which output tile the user has selected — drives eigenvalue-range
    /// highlighting in the eigenvalue chart. `nil` = no tile selected.
    var selectedOutput: SelectedOutput? = nil

    enum SelectedOutput: String, Sendable, CaseIterable {
        case clean, noisy, mp, gen
    }

    // ---- storage location (where downloaded datasets live) -------------

    /// Default sandboxed storage: Application Support / EigenDenoise.
    /// Equivalent of "C:\.eigendenoise" on Windows under macOS sandbox rules.
    private static func defaultStorageURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let dst = support.appendingPathComponent("EigenDenoise", isDirectory: true)
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        return dst
    }
    private static let storageBookmarkKey = "EigenDenoise.storageBookmark"

    /// Where downloaded datasets land. User can change via `pickStorageLocation`.
    var storageURL: URL = AppModel.defaultStorageURL()
    /// True if the storage URL came from a security-scoped bookmark.
    private var storageNeedsScope: Bool = false

    func pickStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Pick a folder where downloaded image datasets will be stored"
        panel.directoryURL = storageURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: AppModel.storageBookmarkKey)
            // Stop access on the previous bookmarked URL if we had one.
            if storageNeedsScope { storageURL.stopAccessingSecurityScopedResource() }
            storageURL = url
            storageNeedsScope = url.startAccessingSecurityScopedResource()
            log("storage → \(url.path)")
        } catch {
            log("could not save storage bookmark: \(error.localizedDescription)")
        }
    }

    func resetStorageToDefault() {
        if storageNeedsScope { storageURL.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.removeObject(forKey: AppModel.storageBookmarkKey)
        storageURL = AppModel.defaultStorageURL()
        storageNeedsScope = false
        log("storage → default (\(storageURL.path))")
    }

    func restoreStorageFromBookmark() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.storageBookmarkKey)
        else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &stale)
            storageURL = url
            storageNeedsScope = url.startAccessingSecurityScopedResource()
            EDLog.log(.folder, "restoreStorageFromBookmark — path=\(url.path) stale=\(stale)")
        } catch {
            EDLog.warn(.folder, "could not resolve storage bookmark: \(error.localizedDescription)")
        }
    }

    // ---- dataset download (URL list) -----------------------------------

    var isDownloading: Bool = false
    var downloadProgress: (done: Int, total: Int, current: String) = (0, 0, "")

    func downloadImages(_ urls: [URL], subfolder: String, autoLoad: Bool = true) {
        guard !urls.isEmpty else { log("no URLs to download"); return }
        guard !isDownloading else { log("a download is already running"); return }
        let dest = storageURL.appendingPathComponent(subfolder, isDirectory: true)
        log("downloading \(urls.count) image(s) → \(dest.path)")
        isDownloading = true
        downloadProgress = (0, urls.count, "")
        let captured = self
        Task {
            let dl = ImageDownloader()
            let written = await dl.download(urls, to: dest) { p in
                Task { @MainActor in
                    captured.downloadProgress = (p.completed, p.total, p.currentURL)
                }
            }
            await MainActor.run {
                captured.isDownloading = false
                captured.log("downloaded \(written)/\(urls.count) image(s) to \(dest.lastPathComponent)/")
                if autoLoad && written > 0 {
                    captured.loadFolder(dest)
                }
            }
        }
    }

    // ---- folder loading -------------------------------------------------

    /// UserDefaults keys for persisted security-scoped bookmark.
    private static let bookmarkKey = "EigenDenoise.folderBookmark"

    /// Discovered subfolders of the user-picked root (for the Image library
    /// quick-pick UI). Under sandbox we can only enumerate folders the user
    /// has explicitly granted access to.
    private(set) var folderSubfolders: [URL] = []

    func loadFolder(_ url: URL) {
        EDLog.log(.folder, "loadFolder — path=\(url.path) resize=\(resizeH)×\(resizeW)")
        // Only persist a security-scoped bookmark for paths OUTSIDE the
        // app's own sandbox container. Paths inside our Application Support
        // (e.g. downloaded datasets) don't need a bookmark — and asking for
        // one with .withSecurityScope can fail on app-owned URLs.
        if !isInsideAppContainer(url) {
            do {
                let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: AppModel.bookmarkKey)
            } catch {
                EDLog.warn(.folder, "failed to write bookmark: \(error.localizedDescription)")
            }
        } else {
            EDLog.log(.folder, "skipping bookmark — path is inside app container")
        }
        loadFolderInternal(url, fromBookmark: false)
    }

    /// Returns true when `url` is rooted inside this app's sandbox container
    /// (Application Support / Caches / Documents / tmp). Such paths are
    /// always readable without a security-scoped bookmark.
    private func isInsideAppContainer(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let containers = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path,
            FileManager.default.urls(for: .cachesDirectory,             in: .userDomainMask).first?.path,
            FileManager.default.urls(for: .documentDirectory,           in: .userDomainMask).first?.path,
            NSTemporaryDirectory() as String?,
        ].compactMap { $0 }
        return containers.contains { path.hasPrefix($0) }
    }

    /// Re-acquire access from a stored bookmark on launch (used by AppDelegate).
    func restoreFolderFromBookmark() {
        guard let data = UserDefaults.standard.data(forKey: AppModel.bookmarkKey)
        else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                                options: .withSecurityScope,
                                relativeTo: nil,
                                bookmarkDataIsStale: &stale)
            EDLog.log(.folder, "restoreFolderFromBookmark — path=\(url.path) stale=\(stale)")
            loadFolderInternal(url, fromBookmark: true)
        } catch {
            EDLog.warn(.folder, "failed to resolve bookmark: \(error.localizedDescription)")
        }
    }

    private func loadFolderInternal(_ url: URL, fromBookmark: Bool) {
        let didStart = url.startAccessingSecurityScopedResource()
        EDLog.log(.folder, "loadFolderInternal — startAccess=\(didStart) fromBookmark=\(fromBookmark)")
        folderURL = url
        // Clear stale state synchronously so the UI reflects the new
        // selection immediately (sub-folder chips, test-image picker,
        // thumbnail grid, etc.). The async ImageIO load below repopulates.
        folderSubfolders = []
        imageNames = []
        imageData = []
        testFilename = ""
        // List sub-folders for the Image library card (sandbox-safe).
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: url.path) {
            folderSubfolders = names
                .filter { n in
                    if n.hasPrefix(".") { return false }
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: url.appendingPathComponent(n).path, isDirectory: &isDir)
                    return isDir.boolValue
                }
                .sorted()
                .map { url.appendingPathComponent($0) }
            EDLog.log(.folder, "found \(folderSubfolders.count) sub-folders")
        }
        log("loading \(url.lastPathComponent) at \(resizeH)×\(resizeW) …")
        let H = resizeH, W = resizeW
        let captured = self
        Task.detached {
            EDLog.log(.folder, "loadFolder.bg — calling ImageIO.loadFolder")
            let loaded = ImageIO.loadFolder(url, H: H, W: W)
            await MainActor.run {
                if didStart { url.stopAccessingSecurityScopedResource() }
                guard let l = loaded else {
                    EDLog.error(.folder, "ImageIO.loadFolder returned nil for \(url.path)")
                    captured.log("failed to load folder — sandbox may be blocking access")
                    return
                }
                EDLog.log(.folder, "loadFolder.bg — got \(l.names.count) images, data=\(l.data.count)")
                captured.imageData = l.data
                captured.imageNames = l.names
                captured.imageH = H
                captured.imageW = W
                captured.testFilename = l.names.first ?? ""
                captured.log("loaded \(l.names.count) images at \(H)×\(W)")
            }
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick a folder of images to denoise"
        // If we already have a working folder URL, default the open panel there.
        if let cur = folderURL { panel.directoryURL = cur }
        if panel.runModal() == .OK, let url = panel.url { loadFolder(url) }
    }

    // ---- Import: copy folder / files into managed storage --------------

    /// Managed-dataset entry surfaced to the FolderView library grid.
    struct ManagedDataset: Identifiable, Hashable, Sendable {
        let id: URL
        let url: URL
        let name: String
        let imageCount: Int
        let totalBytes: Int64
        let modified: Date
        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }
    }

    /// List top-level subfolders of `storageURL` and their image counts /
    /// sizes / mtime. Recursive size, non-recursive image count (matches the
    /// pipeline, which loads from the immediate folder).
    func listManagedDatasets() -> [ManagedDataset] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: storageURL.path)
        else { return [] }
        var out: [ManagedDataset] = []
        for n in names where !n.hasPrefix(".") {
            let url = storageURL.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let images = ImageIO.listImages(in: url)
            // Recursive byte-count for the whole subtree.
            var bytes: Int64 = 0
            if let it = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let f as URL in it {
                    let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if v?.isRegularFile == true { bytes += Int64(v?.fileSize ?? 0) }
                }
            }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            out.append(ManagedDataset(id: url, url: url, name: n,
                                        imageCount: images.count,
                                        totalBytes: bytes, modified: mtime))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// Move a managed dataset to the user's Trash. Returns true on success.
    @discardableResult
    func deleteManagedDataset(_ dataset: ManagedDataset) -> Bool {
        let fm = FileManager.default
        do {
            var resulting: NSURL?
            try fm.trashItem(at: dataset.url, resultingItemURL: &resulting)
            log("trashed dataset \(dataset.name)")
            // If the user trashed the currently-loaded folder, clear UI state.
            if folderURL?.standardizedFileURL == dataset.url.standardizedFileURL {
                folderURL = nil
                folderSubfolders = []
                imageNames = []
                imageData = []
                testFilename = ""
            }
            return true
        } catch {
            log("could not trash \(dataset.name): \(error.localizedDescription)")
            return false
        }
    }

    /// Reveal a URL in Finder.
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Pick a folder of images in any location, copy every image inside
    /// (recursively) into `storageURL/<source folder name>/`, then load it.
    /// Designed to work under the App Store sandbox: the user-granted folder
    /// is read once via security scope; the destination lives inside our
    /// own Application Support container so the bookmarked path persists.
    func importFolderCopy() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Pick a folder of images to import into your Storage"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let didStart = src.startAccessingSecurityScopedResource()
        defer { if didStart { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let baseName = src.lastPathComponent
        let dest = uniqueSubfolder(named: baseName)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var copied = 0
        if let it = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in it {
                let ext = f.pathExtension.lowercased()
                guard ImageIO.imageExtensions.contains(ext) else { continue }
                let target = dest.appendingPathComponent(f.lastPathComponent)
                do {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: f, to: target)
                    copied += 1
                } catch {
                    EDLog.warn(.folder, "import copy failed for \(f.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        log("imported \(copied) image(s) → \(dest.lastPathComponent)/")
        if copied > 0 { loadFolder(dest) }
    }

    /// Pick one or more individual image files and copy them into a chosen
    /// sub-folder of Storage, then load that folder.
    func importFilesCopy(subfolder: String = "imported") {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Pick image files to import into your Storage"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        let dest = uniqueSubfolder(named: subfolder)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var copied = 0
        for f in urls {
            let didStart = f.startAccessingSecurityScopedResource()
            defer { if didStart { f.stopAccessingSecurityScopedResource() } }
            let target = dest.appendingPathComponent(f.lastPathComponent)
            do {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: f, to: target)
                copied += 1
            } catch {
                EDLog.warn(.folder, "import file failed for \(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        log("imported \(copied) file(s) → \(dest.lastPathComponent)/")
        if copied > 0 { loadFolder(dest) }
    }

    /// Returns `storageURL/<name>` or `<name>-2`, `-3`, … if a directory
    /// with that name already exists. Avoids merging into other datasets.
    private func uniqueSubfolder(named name: String) -> URL {
        let fm = FileManager.default
        let safe = name.isEmpty ? "imported" : name
        var candidate = storageURL.appendingPathComponent(safe, isDirectory: true)
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = storageURL.appendingPathComponent("\(safe)-\(i)", isDirectory: true)
            i += 1
        }
        return candidate
    }

    // ---- legacy hooks (kept so DenoiseView/FolderView etc. still compile,
    //                    but they now route through the user-picked folder) -

    /// Legacy: was used to point Browse at /Volumes/D/denoise/downloads.
    /// Under sandbox we no longer auto-discover that path, so this is nil.
    static let imageRoot: URL? = nil

    /// Returns the sub-folders of the *user-picked* root, if one is loaded.
    /// This replaces the previous /Volumes/D/denoise/downloads enumeration
    /// that doesn't work under sandbox.
    static func imageRootSubfolders() -> [URL] {
        AppModel.shared.folderSubfolders
    }

    // ---- run denoise ----------------------------------------------------
    /// Real-image denoising — runs the **native Swift port** of rmt-denoise.
    /// All math goes through Accelerate / Metal. No Python subprocess; works
    /// inside the App Store sandbox. Method name kept for UI binding compat.
    func runDenoiseViaBridge() {
        EDLog.log(.bridge, "runDenoiseViaBridge — isDenoising=\(isDenoising) folder=\(folderURL?.path ?? "nil") imageCount=\(imageCount) test='\(testFilename)'")
        guard !isDenoising else { EDLog.warn(.bridge, "ignored — already running"); return }
        guard !imageNames.isEmpty else { log("no images loaded"); return }
        guard let testIdx = imageNames.firstIndex(of: testFilename) else {
            log("test image '\(testFilename)' not found"); return
        }

        let H = imageH, W = imageW, p = H * W
        let totalImgs = imageCount
        guard totalImgs >= 2 else { log("need at least 2 images"); return }

        // Build clean train + clean test slices.
        let pool = (0..<totalImgs).filter { $0 != testIdx }
        let want = min(max(nTrain, 1), pool.count)
        let trainIdxs = Array(pool.prefix(want))
        let cleanTest: [Float] = Array(imageData[(testIdx * p) ..< ((testIdx + 1) * p)])
        var cleanTrain = [Float](); cleanTrain.reserveCapacity(trainIdxs.count * p)
        for ti in trainIdxs {
            cleanTrain.append(contentsOf: imageData[(ti * p) ..< ((ti + 1) * p)])
        }
        // Joint noise injection (5 kinds, σ in 0–255 scale → divide by 255).
        let stack = cleanTrain + cleanTest
        let noisyStack = noiseConfig.enabled
            ? NoiseInjector.add(stack, n: trainIdxs.count + 1, H: H, W: W,
                                  config: noiseConfig, seed: noiseSeed)
            : stack
        let noisyTrain = Array(noisyStack[0..<(trainIdxs.count * p)])
        let noisyTest  = Array(noisyStack[(trainIdxs.count * p)...])

        let job = NativeDenoise.Job(
            noisyTrain: noisyTrain, cleanTest: cleanTest, noisyTest: noisyTest,
            H: H, W: W,
            method: runMethod.rawValue,
            applyT: applyT, colorResize: colorResize, center: center,
            device: device, deSeed: 42
        )
        log("running native denoise method=\(runMethod.rawValue) device=\(device) n=\(trainIdxs.count) test=\(testFilename) T=\(applyT ? "on" : "off") resize=\(colorResize ? "on" : "off") center=\(center ? "on" : "off") noise=\(noiseConfig.enabled ? noiseConfig.kind.label : "off") …")
        isDenoising = true
        denoiseProgress = (0, "Starting…")
        selectedOutput = nil
        let captured = self
        Task.detached {
            let r = NativeDenoise.run(job) { frac, stage in
                Task { @MainActor in
                    captured.denoiseProgress = (frac, stage)
                }
            }
            await MainActor.run {
                // Synthesise the existing bridge-shaped result so DenoiseView keeps working.
                let synthesised = RMTBridgeResult(
                    cleanPath: "", noisyPath: "", mpPath: "", genPath: "",
                    residualPath: "",
                    psnrMP: r.psnrMP, rankMP: r.rankMP,
                    psnrGen: r.psnrGen, rankGen: r.rankGen,
                    a: r.a, beta: r.beta, sigma2: r.sigma2,
                    elapsed: r.elapsed,
                    eigenvalues: r.eigenvalues,
                    n: r.n, p: r.p, y: r.y,
                    device: r.device,
                    rmtDenoiseVersion: "native"
                )
                captured.lastBridgeResult = synthesised
                captured.bridgeCleanImage    = ImageIO.nsImage(r.cleanImage,    H: r.H, W: r.W)
                captured.bridgeNoisyImage    = ImageIO.nsImage(r.noisyImage,    H: r.H, W: r.W)
                captured.bridgeMPImage       = ImageIO.nsImage(r.mpImage,       H: r.H, W: r.W)
                captured.bridgeGenImage      = ImageIO.nsImage(r.genImage,      H: r.H, W: r.W)
                captured.bridgeResidualImage = ImageIO.nsImage(r.residualImage, H: r.H, W: r.W)
                captured.isDenoising = false
                captured.denoiseProgress = (1.0, "Done")
                captured.log(String(format: "done in %.2fs — MP: PSNR=%.2fdB r̂=%d   Gen-Cov: PSNR=%.2fdB r̂=%d  â=%.3f β̂=%.3f  device=%@",
                                     r.elapsed, r.psnrMP, r.rankMP,
                                     r.psnrGen, r.rankGen, r.a, r.beta,
                                     r.device as NSString))
            }
        }
    }

    /// Native pipeline (used only for the math-tab and dev preview path).
    func runDenoiseNative() {
        guard !isDenoising else { return }
        guard !imageData.isEmpty else { log("no images loaded"); return }
        let p = imageH * imageW
        let totalImgs = imageData.count / p
        guard totalImgs >= 2 else { log("need at least 2 images"); return }
        guard let testIdx = imageNames.firstIndex(of: testFilename) else {
            log("test image '\(testFilename)' not found"); return
        }
        let pool = (0..<totalImgs).filter { $0 != testIdx }
        let want = min(max(nTrain, 1), pool.count)
        let trainIdxs = Array(pool.prefix(want))
        let cleanTest: [Float] = Array(imageData[(testIdx * p) ..< ((testIdx + 1) * p)])
        var cleanTrain = [Float](); cleanTrain.reserveCapacity(trainIdxs.count * p)
        for ti in trainIdxs {
            cleanTrain.append(contentsOf: imageData[(ti * p) ..< ((ti + 1) * p)])
        }
        let stack = cleanTrain + cleanTest
        let noisyStack = NoiseInjector.add(stack,
                                            n: trainIdxs.count + 1,
                                            H: imageH, W: imageW,
                                            config: noiseConfig,
                                            seed: noiseSeed)
        let noisyTrain = Array(noisyStack[0..<(trainIdxs.count * p)])
        let noisyTest  = Array(noisyStack[(trainIdxs.count * p)...])
        let cfg = denoiseConfig
        let H = imageH, W = imageW
        let cleanArg = cfg.method.requiresClean ? cleanTest : nil
        log("native denoise method=\(cfg.method.label) train=\(trainIdxs.count) test=\(testFilename)")
        isDenoising = true
        lastCleanTest = cleanTest
        lastNoisyTest = noisyTest
        let captured = self
        Task.detached {
            do {
                let result = try Denoiser.denoise(train: noisyTrain,
                                                   test: noisyTest,
                                                   clean: cleanArg,
                                                   H: H, W: W,
                                                   config: cfg)
                await MainActor.run {
                    captured.lastNativeResult = result
                    captured.isDenoising = false
                    let r = result.info
                    captured.log(String(format: "native done in %.2fs  â=%.4f  β̂=%.4f  r̂=%d  PSNR=%.3fdB  SSIM=%.4f",
                                         r.elapsedSeconds, r.aHat, r.betaHat, r.rankHat, r.psnr, r.ssim))
                }
            } catch {
                await MainActor.run {
                    captured.isDenoising = false
                    captured.log("error: \(error.localizedDescription)")
                }
            }
        }
    }
}
