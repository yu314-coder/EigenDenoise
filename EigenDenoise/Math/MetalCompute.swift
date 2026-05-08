//
//  MetalCompute.swift
//  GPU-accelerated linear algebra primitives via Metal Performance Shaders.
//
//  Currently exposes:
//    * gramMatrix(X, p, n)  →  X · Xᵀ / n   on GPU (float32) when available,
//                              or via Accelerate cblas_dgemm (float64) otherwise.
//
//  Used by the Eigenvalue-distribution simulation. The eigenvalue solver
//  itself stays on CPU (LAPACK has no MPS counterpart) but the heavy
//  O(p²·n) Gram matmul moves to the GPU.
//

import Accelerate
import Foundation
import Metal
import MetalPerformanceShaders

public enum ComputeDevice: String, Sendable {
    case mps = "Metal (GPU)"
    case accelerate = "Accelerate (CPU)"
    case fallback = "fallback (CPU)"
}

public final class MetalCompute: @unchecked Sendable {
    public nonisolated(unsafe) static let shared = MetalCompute()

    public nonisolated let device: MTLDevice?
    public nonisolated let queue: MTLCommandQueue?
    public nonisolated var isAvailable: Bool { device != nil && queue != nil }

    private init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.queue = dev?.makeCommandQueue()
    }

    /// Computes  S = X · Xᵀ / n  for X ∈ ℝ^{p×n} (row-major, double).
    /// Returns the p×p symmetric matrix row-major plus the device used.
    public nonisolated func gramMatrix(_ X: [Double], p: Int, n: Int) -> (S: [Double], device: ComputeDevice) {
        EDLog.log(.gram, "gram entry — p=\(p) n=\(n) X.count=\(X.count) mps_available=\(isAvailable)")
        if X.count != p * n {
            EDLog.error(.gram, "matrix size mismatch — X.count=\(X.count) expected p*n=\(p * n)")
        }
        precondition(X.count == p * n)
        if isAvailable, let mps = gramViaMPS(X, p: p, n: n) {
            EDLog.log(.gram, "gram via MPS done")
            return (mps, .mps)
        }
        EDLog.log(.gram, "gram via Accelerate cblas_dgemm")
        return (gramViaAccelerate(X, p: p, n: n), .accelerate)
    }

    // MARK: - GPU path (MPS)

    private nonisolated func gramViaMPS(_ X: [Double], p: Int, n: Int) -> [Double]? {
        guard let device = device, let queue = queue else { return nil }
        // MPS-Matrix supports float32 (and float16); we downcast for the matmul,
        // then upcast on the way back. For the histogram-level use this is fine.
        var Xf = [Float](repeating: 0, count: p * n)
        for i in 0..<(p * n) { Xf[i] = Float(X[i]) }
        let bytesA = p * n * MemoryLayout<Float>.size
        let bytesC = p * p * MemoryLayout<Float>.size
        guard let bufA = device.makeBuffer(bytes: Xf, length: bytesA, options: .storageModeShared),
              let bufC = device.makeBuffer(length: bytesC, options: .storageModeShared)
        else { return nil }
        let descA = MPSMatrixDescriptor(rows: p,
                                          columns: n,
                                          rowBytes: n * MemoryLayout<Float>.size,
                                          dataType: .float32)
        let descC = MPSMatrixDescriptor(rows: p,
                                          columns: p,
                                          rowBytes: p * MemoryLayout<Float>.size,
                                          dataType: .float32)
        let A = MPSMatrix(buffer: bufA, descriptor: descA)
        // transposeRight=true ⇒ compute  A · Aᵀ.
        let mm = MPSMatrixMultiplication(device: device,
                                          transposeLeft: false,
                                          transposeRight: true,
                                          resultRows: p, resultColumns: p,
                                          interiorColumns: n,
                                          alpha: 1.0 / Double(n),
                                          beta: 0.0)
        let result = MPSMatrix(buffer: bufC, descriptor: descC)
        guard let cmd = queue.makeCommandBuffer() else { return nil }
        mm.encode(commandBuffer: cmd, leftMatrix: A, rightMatrix: A, resultMatrix: result)
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status != .completed { return nil }
        // Symmetrise tiny round-off asymmetry, upcast to double.
        var S = [Double](repeating: 0, count: p * p)
        let outPtr = bufC.contents().bindMemory(to: Float.self, capacity: p * p)
        for i in 0..<p {
            for j in 0..<p {
                let v = Double(outPtr[i * p + j])
                S[i * p + j] = v
            }
        }
        // Average the two triangles to enforce exact symmetry.
        for i in 0..<p {
            for j in (i + 1)..<p {
                let m = 0.5 * (S[i * p + j] + S[j * p + i])
                S[i * p + j] = m
                S[j * p + i] = m
            }
        }
        return S
    }

    /// Compute Xᵀ X for X ∈ ℝ^{p×n} (row-major, double) on the GPU.
    /// Returns the n×n result row-major plus the device used. No scaling.
    public nonisolated func gramSmall(_ X: [Double], p: Int, n: Int) -> (S: [Double], device: ComputeDevice)? {
        precondition(X.count == p * n)
        guard isAvailable, let device = device, let queue = queue else { return nil }
        var Xf = [Float](repeating: 0, count: p * n)
        for i in 0..<(p * n) { Xf[i] = Float(X[i]) }
        let bytesA = p * n * MemoryLayout<Float>.size
        let bytesC = n * n * MemoryLayout<Float>.size
        guard let bufA = device.makeBuffer(bytes: Xf, length: bytesA, options: .storageModeShared),
              let bufC = device.makeBuffer(length: bytesC, options: .storageModeShared)
        else { return nil }
        let descA = MPSMatrixDescriptor(rows: p, columns: n,
                                          rowBytes: n * MemoryLayout<Float>.size,
                                          dataType: .float32)
        let descC = MPSMatrixDescriptor(rows: n, columns: n,
                                          rowBytes: n * MemoryLayout<Float>.size,
                                          dataType: .float32)
        let A = MPSMatrix(buffer: bufA, descriptor: descA)
        let C = MPSMatrix(buffer: bufC, descriptor: descC)
        let mm = MPSMatrixMultiplication(device: device,
                                          transposeLeft: true,
                                          transposeRight: false,
                                          resultRows: n, resultColumns: n,
                                          interiorColumns: p,
                                          alpha: 1.0, beta: 0.0)
        guard let cmd = queue.makeCommandBuffer() else { return nil }
        mm.encode(commandBuffer: cmd, leftMatrix: A, rightMatrix: A, resultMatrix: C)
        cmd.commit(); cmd.waitUntilCompleted()
        if cmd.status != .completed { return nil }
        var S = [Double](repeating: 0, count: n * n)
        let outPtr = bufC.contents().bindMemory(to: Float.self, capacity: n * n)
        for i in 0..<n {
            for j in 0..<n { S[i * n + j] = Double(outPtr[i * n + j]) }
        }
        // Symmetrise round-off asymmetry.
        for i in 0..<n {
            for j in (i + 1)..<n {
                let m = 0.5 * (S[i * n + j] + S[j * n + i])
                S[i * n + j] = m; S[j * n + i] = m
            }
        }
        return (S, .mps)
    }

    /// Generic GPU matmul: returns A · B (row-major, double) where A is
    /// `aRows × aCols` row-major and B is `bRows × bCols` row-major. Returns
    /// nil when MPS is unavailable or the command buffer doesn't complete.
    public nonisolated func matmul(_ A: [Double], aRows: Int, aCols: Int,
                                     _ B: [Double], bRows: Int, bCols: Int) -> [Double]? {
        precondition(A.count == aRows * aCols)
        precondition(B.count == bRows * bCols)
        precondition(aCols == bRows)
        guard isAvailable, let device = device, let queue = queue else { return nil }
        var Af = [Float](repeating: 0, count: A.count)
        var Bf = [Float](repeating: 0, count: B.count)
        for i in 0..<A.count { Af[i] = Float(A[i]) }
        for i in 0..<B.count { Bf[i] = Float(B[i]) }
        let bytesA = A.count * MemoryLayout<Float>.size
        let bytesB = B.count * MemoryLayout<Float>.size
        let bytesC = aRows * bCols * MemoryLayout<Float>.size
        guard let bufA = device.makeBuffer(bytes: Af, length: bytesA, options: .storageModeShared),
              let bufB = device.makeBuffer(bytes: Bf, length: bytesB, options: .storageModeShared),
              let bufC = device.makeBuffer(length: bytesC, options: .storageModeShared)
        else { return nil }
        let descA = MPSMatrixDescriptor(rows: aRows, columns: aCols,
                                          rowBytes: aCols * MemoryLayout<Float>.size,
                                          dataType: .float32)
        let descB = MPSMatrixDescriptor(rows: bRows, columns: bCols,
                                          rowBytes: bCols * MemoryLayout<Float>.size,
                                          dataType: .float32)
        let descC = MPSMatrixDescriptor(rows: aRows, columns: bCols,
                                          rowBytes: bCols * MemoryLayout<Float>.size,
                                          dataType: .float32)
        let mA = MPSMatrix(buffer: bufA, descriptor: descA)
        let mB = MPSMatrix(buffer: bufB, descriptor: descB)
        let mC = MPSMatrix(buffer: bufC, descriptor: descC)
        let mm = MPSMatrixMultiplication(device: device,
                                          transposeLeft: false, transposeRight: false,
                                          resultRows: aRows, resultColumns: bCols,
                                          interiorColumns: aCols,
                                          alpha: 1.0, beta: 0.0)
        guard let cmd = queue.makeCommandBuffer() else { return nil }
        mm.encode(commandBuffer: cmd, leftMatrix: mA, rightMatrix: mB, resultMatrix: mC)
        cmd.commit(); cmd.waitUntilCompleted()
        if cmd.status != .completed { return nil }
        var C = [Double](repeating: 0, count: aRows * bCols)
        let outPtr = bufC.contents().bindMemory(to: Float.self, capacity: aRows * bCols)
        for i in 0..<(aRows * bCols) { C[i] = Double(outPtr[i]) }
        return C
    }

    // MARK: - CPU path (Accelerate cblas_dgemm)

    private nonisolated func gramViaAccelerate(_ X: [Double], p: Int, n: Int) -> [Double] {
        var S = [Double](repeating: 0, count: p * p)
        // C = (1/n) · A · Bᵀ  with A = B = X.
        cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    Int32(p), Int32(p), Int32(n),
                    1.0 / Double(n),
                    X, Int32(n),
                    X, Int32(n),
                    0.0,
                    &S, Int32(p))
        return S
    }
}
