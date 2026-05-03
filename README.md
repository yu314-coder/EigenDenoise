# EigenDenoise

A native macOS application for **image denoising and spectral analysis**
based on random matrix theory (RMT). Pure-Swift, Metal-accelerated, App
Store sandbox-ready.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## What it does

Two complementary RMT-based denoisers run on the same noisy image stack,
side-by-side with three interactive tabs that visualise the underlying
mathematics:

- **Marchenko–Pastur thresholding** — classical singular-value cutoff at
  the bulk edge `(1 + √y)·√(λ_p/q)`, using the spread rule from the batch
  MPPCA literature.
- **Generalized-covariance oracle** — models the bulk via the limiting
  spectral density of `B_n = S_n T_n` with two-point spike weight
  `H = β·δ_a + (1−β)·δ_1`. Best `(a, β)` is found by differential
  evolution against a held-out clean reference.
- **Spectral visualisations** — Eigenvalue distribution (Monte-Carlo
  histogram + closed-form `F_{y,H}(z)` overlay + Case 1/2/3 support
  edges), Im(s) vs z (Stieltjes-transform imaginary part), Roots vs β
  (cubic-root behaviour over the spike fraction).

## Features

- **Five noise models** — Gaussian, Mixture-of-Gaussians, Two-Point H,
  Half-Gaussian, Block-Half. Seedable for reproducibility.
- **Curated dataset gallery** — one-click downloads in the Datasets tab:
  - ORL (AT&T) Faces — 400 PGMs
  - CBSD68 — 68 colour Berkeley test images
  - Brain Tumor MRI — 3,264 T1 slices (live GitHub listing)
  - Custom URL lists with per-image checkboxes and destination preview
- **Metal GPU acceleration** — `MPSMatrixMultiplication` for the Gram
  step on Apple Silicon, transparent Accelerate (BLAS / LAPACK) fallback.
  Eigen-decomposition uses LAPACK `dsyevd`.
- **Sandboxed storage** — datasets save to your sandboxed Application
  Support folder by default; pick any local folder via security-scoped
  bookmark and the choice persists across launches.
- **No telemetry, no analytics, no sign-in** — all computation is local;
  network is touched only when you explicitly click a preset or paste
  URLs and press Download.

## Build

Requires Xcode 15.4+ on macOS 14 (Sonoma) or later.

```bash
git clone https://github.com/yu314-coder/EigenDenoise.git
cd EigenDenoise
open EigenDenoise.xcodeproj
# ⌘R
```

There are no external Swift package dependencies — Charts and SwiftUI
ship with the OS. The project targets `arm64` (Apple Silicon) and works
under Rosetta on Intel; Metal acceleration falls back to Accelerate when
no Metal device is present.

## Layout

```
EigenDenoise/
├── EigenDenoise.xcodeproj/
├── EigenDenoise/
│   ├── EigenDenoiseApp.swift       @main + menu commands
│   ├── ContentView.swift
│   ├── EigenDenoise.entitlements   App Sandbox = YES
│   ├── Math/                       RMT, Eigh, MetalCompute, SpectralDensity, …
│   ├── Denoise/                    NativeDenoise, NoiseInjection, ImageIO, …
│   ├── UI/                         AppModel, FolderView, DenoiseView, …
│   └── Assets.xcassets/
├── icons/
└── scripts/
```

## Mathematics in brief

For `X ∈ ℝ^{p×n}` with i.i.d. `N(0, 1)` entries, `S_n = (1/n) X Xᵀ`
and `T_n = diag(t₁,…,t_p)` with empirical distribution
`F^{T_n} ⇒ H = β·δ_a + (1−β)·δ_1`, the generalized sample covariance
matrix is `B_n = S_n T_n`. Its Stieltjes transform `s(z)` satisfies
the cubic

```
a·z·s³ + (a(z − y + 1) + z)·s² + (a + z − y + 1 − y·β·(a − 1))·s + 1 = 0
```

with concentration ratio `y = p / n`. The closed-form limiting density
`f_{y,H}(z)` follows from Cardano's depressed-cubic root, and the
support is recovered from the bulk-edge function `g(t)` plus the
discriminant of the quartic `P_4(t)` for one-interval (Cases 1, 3) vs
two-interval (Case 2) topology. Both are implemented in
[`Math/SpectralDensity.swift`](EigenDenoise/Math/SpectralDensity.swift).

## License

MIT — see [LICENSE](LICENSE).

## Author

Yao-Hsing Yu · `euler.yu@gmail.com` · [@yu314-coder](https://github.com/yu314-coder)
