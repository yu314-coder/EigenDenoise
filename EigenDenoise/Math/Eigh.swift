//
//  Eigh.swift
//  Symmetric real eigenvalue decomposition via Accelerate (`dsyevd`).
//  Used by the Eigenvalue-distribution simulation: B_n = S_n × T_n where
//  S_n = X Xᵀ / n is sample covariance and T_n is diagonal with βp spike
//  entries of value a and the rest 1. Eigenvalues of S T equal those of
//  the symmetric matrix M = T^{1/2} S T^{1/2}, computed here.
//

import Accelerate
@preconcurrency import Foundation

public enum SymEigen {
    /// Eigenvalues of an n×n symmetric matrix supplied row-major in `A`.
    /// Returns ascending values; LAPACK is allowed to overwrite `A`.
    public static func eigenvalues(_ A: [Double], n: Int) -> [Double] {
        EDLog.log(.eigh, "eigh entry — n=\(n) A.count=\(A.count)")
        if A.count != n * n {
            EDLog.error(.eigh, "matrix size mismatch — A.count=\(A.count) expected n*n=\(n * n)")
        }
        precondition(A.count == n * n)
        var Acopy = A
        var jobz: Int8 = 0x4E         // 'N' — eigenvalues only
        var uplo: Int8 = 0x55         // 'U'
        var nl = __CLPK_integer(n)
        var lda = __CLPK_integer(n)
        var w = [Double](repeating: 0.0, count: n)
        var info: __CLPK_integer = 0
        // Workspace query
        var workQ: Double = 0
        var lwork: __CLPK_integer = -1
        var iworkQ: __CLPK_integer = 0
        var liwork: __CLPK_integer = -1
        Acopy.withUnsafeMutableBufferPointer { ap in
            w.withUnsafeMutableBufferPointer { wp in
                _ = dsyevd_(&jobz, &uplo, &nl, ap.baseAddress, &lda, wp.baseAddress,
                             &workQ, &lwork, &iworkQ, &liwork, &info)
            }
        }
        lwork = __CLPK_integer(workQ)
        liwork = iworkQ > 0 ? iworkQ : __CLPK_integer(1)
        var work = [Double](repeating: 0.0, count: Int(lwork))
        var iwork = [__CLPK_integer](repeating: 0, count: Int(liwork))
        Acopy.withUnsafeMutableBufferPointer { ap in
            w.withUnsafeMutableBufferPointer { wp in
                work.withUnsafeMutableBufferPointer { wkp in
                    iwork.withUnsafeMutableBufferPointer { iwkp in
                        _ = dsyevd_(&jobz, &uplo, &nl, ap.baseAddress, &lda, wp.baseAddress,
                                     wkp.baseAddress, &lwork, iwkp.baseAddress, &liwork, &info)
                    }
                }
            }
        }
        return w
    }

    /// Full eigendecomposition of an n×n symmetric matrix supplied row-major.
    /// Returns ascending eigenvalues `w` (length n) and column-major
    /// eigenvectors `V` (length n*n) such that A = V · diag(w) · Vᵀ.
    public nonisolated static func eigh(_ A: [Double], n: Int) -> (w: [Double], V: [Double]) {
        precondition(A.count == n * n)
        var Acopy = A   // dsyevd will overwrite with eigenvectors (column-major).
        var jobz: Int8 = 0x56         // 'V' — values + vectors
        var uplo: Int8 = 0x55         // 'U'
        var nl = __CLPK_integer(n)
        var lda = __CLPK_integer(n)
        var w = [Double](repeating: 0.0, count: n)
        var info: __CLPK_integer = 0
        var workQ: Double = 0
        var lwork: __CLPK_integer = -1
        var iworkQ: __CLPK_integer = 0
        var liwork: __CLPK_integer = -1
        Acopy.withUnsafeMutableBufferPointer { ap in
            w.withUnsafeMutableBufferPointer { wp in
                _ = dsyevd_(&jobz, &uplo, &nl, ap.baseAddress, &lda, wp.baseAddress,
                             &workQ, &lwork, &iworkQ, &liwork, &info)
            }
        }
        lwork = __CLPK_integer(workQ)
        liwork = iworkQ > 0 ? iworkQ : __CLPK_integer(1)
        var work = [Double](repeating: 0.0, count: Int(lwork))
        var iwork = [__CLPK_integer](repeating: 0, count: Int(liwork))
        Acopy.withUnsafeMutableBufferPointer { ap in
            w.withUnsafeMutableBufferPointer { wp in
                work.withUnsafeMutableBufferPointer { wkp in
                    iwork.withUnsafeMutableBufferPointer { iwkp in
                        _ = dsyevd_(&jobz, &uplo, &nl, ap.baseAddress, &lda, wp.baseAddress,
                                     wkp.baseAddress, &lwork, iwkp.baseAddress, &liwork, &info)
                    }
                }
            }
        }
        return (w, Acopy)
    }
}


// MARK: - Synthesised B_n = S_n × T_n eigenvalues

public struct SpikedSimulationResult: Sendable {
    public let eigenvalues: [Double]
    public let device: ComputeDevice
    public let elapsedSec: Double
}

public enum SpikedSimulation {
    /// Generate eigenvalues of B_n = S_n T_n with the parameters used by the
    /// random_matrix_ESD `Generate Distribution` button.
    ///
    /// • X ∈ ℝ^{p×n} has i.i.d. N(0, 1) entries (seeded).
    /// • S_n = (1/n) X Xᵀ.
    /// • T_n = diag(t₁, …, t_p) with t_i = a for i < ⌊β·p⌋, else 1.
    ///
    /// Heavy step (X·Xᵀ Gram matmul) goes through MetalCompute, which
    /// uses MPSMatrixMultiplication on the GPU when available and
    /// Accelerate cblas_dgemm otherwise. Returns the p ascending
    /// eigenvalues of B = S × T together with the device that was used.
    public nonisolated static func eigenvalues(p: Int, n: Int, a: Double, beta: Double,
                                                 seed: UInt64,
                                                 forceCPU: Bool = false,
                                                 progress: (@Sendable (Double, String) -> Void)? = nil)
        -> SpikedSimulationResult
    {
        EDLog.log(.sim, "spiked simulation — p=\(p) n=\(n) a=\(a) beta=\(beta) seed=\(seed) forceCPU=\(forceCPU)")
        if p <= 0 || n <= 0 {
            EDLog.error(.sim, "invalid dims p=\(p) n=\(n)")
        }
        precondition(p > 0 && n > 0)
        let t0 = Date()
        progress?(0.05, "Sampling X ~ N(0,1) (\(p)×\(n))")
        var rng = EighNormalRNG(seed: seed)
        var X = [Double](repeating: 0, count: p * n)
        for i in 0..<(p * n) { X[i] = rng.next() }

        progress?(0.30, "Computing Gram S = (1/n) X Xᵀ")
        let (S, gramDevice): ([Double], ComputeDevice) = {
            if forceCPU {
                return (cpuGram(X, p: p, n: n), .accelerate)
            }
            return MetalCompute.shared.gramMatrix(X, p: p, n: n)
        }()

        progress?(0.55, "Building T^{1/2} S T^{1/2}")
        let kSpike = Int((Double(p) * beta).rounded(.down))
        var M = [Double](repeating: 0, count: p * p)
        for i in 0..<p {
            let ti = i < kSpike ? sqrt(a) : 1.0
            for j in 0..<p {
                let tj = j < kSpike ? sqrt(a) : 1.0
                M[i * p + j] = S[i * p + j] * ti * tj
            }
        }
        progress?(0.70, "Eigendecomposing (LAPACK dsyevd, p=\(p))")
        let eigs = SymEigen.eigenvalues(M, n: p)
        progress?(1.0, "Done")
        let dt = Date().timeIntervalSince(t0)
        return .init(eigenvalues: eigs, device: gramDevice, elapsedSec: dt)
    }

    /// Direct CPU Gram (used when forceCPU=true).
    private nonisolated static func cpuGram(_ X: [Double], p: Int, n: Int) -> [Double] {
        var S = [Double](repeating: 0, count: p * p)
        Accelerate.cblas_dgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(p), Int32(p), Int32(n),
                                1.0 / Double(n),
                                X, Int32(n),
                                X, Int32(n),
                                0.0,
                                &S, Int32(p))
        return S
    }
}


// Local Box-Muller normal RNG (kept here to avoid making the one in
// NoiseInjection.swift public). Deterministic given seed.
private struct EighNormalRNG {
    var state: UInt64
    var hasSpare = false
    var spare: Double = 0
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func nextU64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double {
        Double(nextU64() >> 11) * (1.0 / Double(1 << 53))
    }
    mutating func next() -> Double {
        if hasSpare { hasSpare = false; return spare }
        var u1: Double, u2: Double, s: Double
        repeat {
            u1 = uniform() * 2 - 1
            u2 = uniform() * 2 - 1
            s = u1 * u1 + u2 * u2
        } while s == 0 || s >= 1
        let mul = sqrt(-2.0 * log(s) / s)
        spare = u2 * mul
        hasSpare = true
        return u1 * mul
    }
}
