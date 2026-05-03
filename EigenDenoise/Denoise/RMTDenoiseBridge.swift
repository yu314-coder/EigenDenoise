//
//  RMTDenoiseBridge.swift
//  Spawns `python3 run_rmt_denoise.py` with a JSON job description, parses
//  the trailing `RESULT {...}` line, returns paths to the written PNGs.
//

import AppKit
import Foundation

public enum DenoiseRunMethod: String, CaseIterable, Identifiable, Sendable {
    case both, mp, gencov
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .both:   return "Run both M-P + Gen-Cov"
        case .mp:     return "Classical M-P only"
        case .gencov: return "Gen-Cov (rmt-denoise) only"
        }
    }
}

public struct RMTBridgeJob: Codable, Sendable {
    public var folder: String
    public var outDir: String
    public var testName: String
    public var nTrain: Int
    public var size: [Int]                     // [H, W]
    public var noise: NoiseSpec
    public var device: String                  // "auto" / "cpu" / "mps"
    public var method: String                  // "both" / "mp" / "gencov"
    public var applyT: Bool                    // T(a, β) post-processing
    public var colorResize: Bool               // (x − min)/max normalisation
    public var center: Bool                    // X̃ = X − X̄ before SVD

    public struct NoiseSpec: Codable, Sendable {
        public var kind: String          // gaussian | mog | twopoint | half_gaussian | block_half
        public var seed: UInt64
        // Gaussian
        public var sigma: Double
        public var mu: Double
        // Mixture of Gaussians
        public var mog_s1: Double
        public var mog_m1: Double
        public var mog_w1: Double
        public var mog_s2: Double
        public var mog_m2: Double
        // Two-Point H
        public var tp_sigma: Double
        public var tp_a: Double
        public var tp_beta: Double
        // Half Gaussian (random 50 % of entries)
        public var hg_sigma: Double
        public var hg_mu: Double
        // Block Half (top-left p/2 × n/2 block)
        public var bh_sigma: Double
        public var bh_mu: Double
    }

    enum CodingKeys: String, CodingKey {
        case folder, testName = "test_name", outDir = "out_dir",
             nTrain = "n_train", size, noise, device, method,
             applyT = "apply_t", colorResize = "color_resize", center
    }
}

public struct RMTBridgeResult: Codable, Sendable {
    public let cleanPath: String
    public let noisyPath: String
    public let mpPath: String
    public let genPath: String
    public let residualPath: String
    public let psnrMP: Double
    public let rankMP: Int
    public let psnrGen: Double
    public let rankGen: Int
    public let a: Double
    public let beta: Double
    public let sigma2: Double
    public let elapsed: Double
    public let eigenvalues: [Double]
    public let n: Int
    public let p: Int
    public let y: Double
    public let device: String
    public let rmtDenoiseVersion: String

    enum CodingKeys: String, CodingKey {
        case cleanPath = "clean_path", noisyPath = "noisy_path",
             mpPath = "mp_path",       genPath = "gen_path",
             residualPath = "residual_path",
             psnrMP = "psnr_mp",       rankMP = "rank_mp",
             psnrGen = "psnr_gen",     rankGen = "rank_gen",
             a, beta, sigma2, elapsed, eigenvalues,
             n, p, y, device,
             rmtDenoiseVersion = "rmt_denoise_version"
    }
}

public enum RMTBridgeError: LocalizedError {
    case interpreterNotFound
    case scriptNotFound
    case spawnFailed(String)
    case noResultLine(String)
    case decodingFailed(String)
    public var errorDescription: String? {
        switch self {
        case .interpreterNotFound:    return "No Python interpreter with rmt-denoise installed was found."
        case .scriptNotFound:         return "Bundled run_rmt_denoise.py is missing."
        case .spawnFailed(let m):     return "Spawning Python failed: \(m)"
        case .noResultLine(let s):    return "Python did not emit a RESULT line. Tail: \(s.suffix(400))"
        case .decodingFailed(let m):  return "Could not decode result JSON: \(m)"
        }
    }
}

private actor LogCollector {
    private var buf = ""
    func append(_ s: String) { buf += s }
    var text: String { buf }
}

public actor RMTDenoiseBridge {

    public init() {}

    // ---------------------------------------------------------------- paths

    /// Resolve the python interpreter to use. Order:
    ///   1. `EIGENDENOISE_PYTHON` env override
    ///   2. Bundled `Contents/Resources/python/.venv/bin/python3`
    ///   3. Dev legacy `/Volumes/D/denoise/.venv/bin/python3` (has rmt-denoise)
    ///   4. `/usr/bin/env python3`
    public static func resolveInterpreter() -> URL? {
        // 1. env override
        if let env = ProcessInfo.processInfo.environment["EIGENDENOISE_PYTHON"] {
            let u = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        // 2. bundled venv (Contents/Resources/python/.venv/bin/python3) — the
        //    sandboxed App Store path. Lookup via Bundle.resourceURL because
        //    Bundle.url(forResource: …) won't follow into a copied venv tree
        //    that wasn't registered as a top-level resource.
        if let res = Bundle.main.resourceURL {
            let inBundle = res.appendingPathComponent("python/.venv/bin/python3")
            if FileManager.default.isExecutableFile(atPath: inBundle.path) {
                return inBundle
            }
        }
        // 3. dev fallbacks (only valid outside the sandbox).
        for c in [
            "/Volumes/D/EigenDenoise/python_bundle/.venv/bin/python3",
            "/Volumes/D/denoise/.venv/bin/python3",
        ] where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    public static func resolveScript() -> URL? {
        // Bundled location: Contents/Resources/python/run_rmt_denoise.py
        if let res = Bundle.main.resourceURL {
            let inBundle = res.appendingPathComponent("python/run_rmt_denoise.py")
            if FileManager.default.fileExists(atPath: inBundle.path) {
                return inBundle
            }
        }
        let dev = URL(fileURLWithPath:
            "/Volumes/D/EigenDenoise/EigenDenoise/Resources/python/run_rmt_denoise.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // -------------------------------------------------------------- public

    public func run(job: RMTBridgeJob,
                     log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RMTBridgeResult {
        EDLog.log(.bridge, "bridge.run — folder=\(job.folder) test=\(job.testName) nTrain=\(job.nTrain) size=\(job.size) device=\(job.device) method=\(job.method) sigma=\(job.noise.sigma) T=\(job.applyT) resize=\(job.colorResize) center=\(job.center)")
        guard let py = Self.resolveInterpreter() else {
            EDLog.error(.bridge, "no interpreter found")
            throw RMTBridgeError.interpreterNotFound
        }
        guard let script = Self.resolveScript() else {
            EDLog.error(.bridge, "no script found")
            throw RMTBridgeError.scriptNotFound
        }
        EDLog.log(.bridge, "bridge.run — interpreter=\(py.path) script=\(script.path)")

        // Encode job as JSON, write to a tmp file (avoids stdin race).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("eigen-denoise-job-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(job).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        if py.lastPathComponent == "env" {
            process.executableURL = py
            process.arguments = ["python3", script.path, "--job", tmp.path]
        } else {
            process.executableURL = py
            process.arguments = [script.path, "--job", tmp.path]
        }
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        process.environment = env

        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        // Use an actor-isolated buffer so concurrent pipe handlers can append safely.
        let collector = LogCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { await collector.append(s) }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = String(line)
                if !trimmed.isEmpty { log(trimmed) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = String(line)
                if !trimmed.isEmpty { log("[py-err] " + trimmed) }
            }
        }
        do {
            try process.run()
        } catch {
            throw RMTBridgeError.spawnFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        // Drain anything still buffered.
        let tailData = outPipe.fileHandleForReading.readDataToEndOfFile()
        if let tail = String(data: tailData, encoding: .utf8) { await collector.append(tail) }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let collectedOut = await collector.text
        guard let lastResult = collectedOut
                .split(separator: "\n", omittingEmptySubsequences: true)
                .last(where: { $0.hasPrefix("RESULT ") })
        else {
            throw RMTBridgeError.noResultLine(collectedOut)
        }
        let jsonText = String(lastResult.dropFirst("RESULT ".count))
        guard let data = jsonText.data(using: .utf8) else {
            throw RMTBridgeError.decodingFailed("could not encode result as utf-8")
        }
        do {
            return try JSONDecoder().decode(RMTBridgeResult.self, from: data)
        } catch {
            throw RMTBridgeError.decodingFailed(error.localizedDescription)
        }
    }
}
