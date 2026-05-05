//
//  EigenvalueView.swift
//  Synthetic random-matrix eigenvalue distribution — matches the
//  `Eigenvalue distribution` tab in random_matrix_ESD/app.py exactly:
//
//      X ∈ ℝ^{p×n} with i.i.d. N(0, 1) entries (seeded)
//      S_n = (1/n) X Xᵀ
//      T_n = diag(a, …, a, 1, …, 1)  with ⌊β·p⌋ spikes of value a
//      B_n = S_n × T_n   ← eigenvalues plotted here
//
//  This tab does NOT use the loaded image folder.
//

import Charts
import SwiftUI

struct EigenvalueView: View {
    @State private var beta: Double = 0.5
    @State private var a: Double = 2.0
    @State private var nSamples: Int = 400
    @State private var pRows: Int = 200
    @State private var seed: UInt64 = 42
    @State private var bins: Int = 60
    @State private var showMP = true
    @State private var showGen = true

    @State private var eigs: [Double] = []
    @State private var elapsed: Double = 0
    @State private var running = false
    @State private var useGPU: Bool = MetalCompute.shared.isAvailable
    @State private var deviceUsed: ComputeDevice = .accelerate
    @State private var showFyH: Bool = true       // Yu (2025) closed-form density overlay
    @State private var progressFraction: Double = 0
    @State private var progressStage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EmptyView().onAppear {
                EDLog.log(.ui, "EigenvalueView appear — useGPU=\(useGPU) eigs=\(eigs.count)")
            }
            SectionHeading(title: "Eigenvalue distribution",
                            systemImage: "chart.bar.fill",
                            subtitle: "Simulate B_n = S_n × T_n with diagonal spike matrix; plot eigenvalues")

            ControlPlotLayout(
                controls: { controlsCard },
                plots: { plotsCard }
            )
        }
    }

    // ---------- controls -------------------------------------------------

    private var controlsCard: some View {
        Card(title: "Parameters", systemImage: "slider.horizontal.3") {
            InlineField(label: "Beta (β)", value: $beta)
            InlineField(label: "Spike (a)", value: $a)
            Divider()
            Text("Matrix dimensions  ·  X ∈ ℝ^{p×n}  ·  S_n = (1/n) X Xᵀ  is p×p")
                .font(.caption.bold()).foregroundStyle(Palette.muted)
            InlineField(label: "Rows (p)",    value: $pRows)
            InlineField(label: "Samples (n)", value: $nSamples)
            HStack(spacing: 6) {
                Image(systemName: "function").foregroundStyle(Palette.accent)
                Text("y = p / n = \(String(format: "%.4f", Double(pRows) / max(Double(nSamples), 1)))")
                    .font(.system(size: 12, design: .monospaced).bold())
                    .foregroundStyle(Palette.text)
                Spacer()
            }
            Divider()
            InlineField(label: "Random seed", value: $seed)
            Divider()
            HStack(spacing: 10) {
                Toggle("MP edges",     isOn: $showMP).toggleStyle(.switch)
                Toggle("Gen-MP edges", isOn: $showGen).toggleStyle(.switch)
            }
            Toggle(isOn: $showFyH) {
                HStack(spacing: 4) {
                    Image(systemName: "function")
                    Text("F_{y,H}(z) curve")
                }
            }
            .toggleStyle(.switch)
            InlineField(label: "Histogram bins", value: $bins)
            Divider()
            Toggle(isOn: $useGPU) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu.fill")
                    Text("Use Metal GPU")
                }
            }
            .toggleStyle(.switch)
            .disabled(!MetalCompute.shared.isAvailable)
            if !MetalCompute.shared.isAvailable {
                Text("Metal device not available — falling back to Accelerate CPU.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Button {
                generate()
            } label: {
                Label(running ? "Computing…" : "Generate distribution",
                      systemImage: running ? "arrow.triangle.2.circlepath" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(running)
            Text("Simulates random matrix eigenvalues with mixed diagonal entries (does not use the loaded image folder).")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }

    // ---------- plots ----------------------------------------------------

    private var plotsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            progressBar
            Card(title: "Matrix construction & theory", systemImage: "function",
                  trailing: AnyView(researchPaperLink)) {
                EquationPanel(title: "Matrix model & spike construction") {
                    Text("B_n = S_n × T_n")
                    Text("S_n = (1/n) · X · Xᵀ      with X ~ N(0, 1)^{p×n}")
                    Text("T_n = diag(a, …, a, 1, …, 1)   first ⌊β·p⌋ entries are a")
                    Text("y = p / n   ·   a = spike value   ·   β = spike fraction")
                }
                paperBlurb
            }
            Card(title: "Eigenvalue histogram", systemImage: "chart.bar.xaxis",
                  trailing: AnyView(
                    HStack(spacing: 8) {
                        if !eigs.isEmpty {
                            Pill(text: deviceUsed.rawValue,
                                 color: deviceUsed == .mps ? .purple : .gray,
                                 systemImage: "cpu.fill")
                        }
                        Pill(text: eigs.isEmpty ? "no data" :
                                    "p=\(pRows)  n=\(nSamples)  y=p/n=\(String(format: "%.4f", Double(pRows) / Double(nSamples)))",
                             color: eigs.isEmpty ? .gray : Palette.accent,
                             systemImage: "function")
                    }
                  )
            ) {
                if eigs.isEmpty {
                    placeholder("Click Generate to create the distribution.")
                } else {
                    chart
                    statsRow
                    supportRow
                }
            }
        }
    }

    private func placeholder(_ s: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                .fill(Color(white: 0.96))
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(Palette.accent)
                Text(s).font(.callout).foregroundStyle(Palette.muted)
            }
        }
        .frame(minHeight: 280)
    }

    @ViewBuilder
    private var chart: some View {
        // When p > n, S_n has p − n exact zeros (rank deficiency); drop them
        // so the bulk distribution isn't squashed by a giant spike at 0.
        let zeroThresh = max(1e-8, (eigs.max() ?? 0) * 1e-6)
        let nonZero = eigs.filter { $0 > zeroThresh }
        let counts = histogram(nonZero, bins: bins)
        let y = Double(pRows) / Double(nSamples)
        let mpLow = pow(1 - sqrt(y), 2)
        let mpHi  = pow(1 + sqrt(y), 2)
        let edges = RMT.bulkEdges(a: a, beta: beta, y: y)
        // Closed-form density samples (from Yu 2025), split per support component.
        let segs: [[(Double, Double)]] = showFyH
            ? SpectralDensity.sampleDensitySegments(a: a, beta: beta, y: y,
                                                     sigma2: 1.0,
                                                     points: 12000,
                                                     padding: 0.0)
            : []
        let maxCount = counts.map { $0.count }.max() ?? 1
        let maxDensity = segs.flatMap { $0 }.map { $0.1 }.max() ?? 0
        let densityScale = (maxDensity > 0)
            ? Double(maxCount) / maxDensity * 0.9
            : 1.0
        let curves: [[DensityPt]] = segs.map { seg in
            seg.map { DensityPt(z: $0.0, v: $0.1 * densityScale) }
        }
        Chart {
            ForEach(counts) { b in
                BarMark(x: .value("λ", b.center), y: .value("count", b.count))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.accent2],
                                                     startPoint: .top, endPoint: .bottom))
                    .opacity(0.65)
            }
            if showFyH {
                ForEach(Array(curves.enumerated()), id: \.offset) { (idx, seg) in
                    ForEach(seg) { p in
                        LineMark(x: .value("z", p.z),
                                 y: .value("F_{y,H}(z)", p.v),
                                 series: .value("seg", idx))
                            .foregroundStyle(.red)
                            .interpolationMethod(.monotone)
                            .lineStyle(.init(lineWidth: 2.0))
                    }
                }
            }
            if showMP, y > 0 {
                RuleMark(x: .value("MP −", mpLow)).foregroundStyle(.blue).lineStyle(.init(dash: [4, 3]))
                RuleMark(x: .value("MP +", mpHi)).foregroundStyle(.blue).lineStyle(.init(dash: [4, 3]))
            }
            if showGen, y > 0 {
                RuleMark(x: .value("Gen −", edges.gMinus)).foregroundStyle(.red)
                RuleMark(x: .value("Gen +", edges.gPlus)).foregroundStyle(.red)
            }
            if let lmin = nonZero.min(), let lmax = nonZero.max() {
                RuleMark(x: .value("λ_min", lmin))
                    .foregroundStyle(.green)
                    .lineStyle(.init(lineWidth: 1.5, dash: [2, 2]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("λ_min=\(String(format: "%.3f", lmin))")
                            .font(.caption2.bold()).foregroundStyle(.green)
                    }
                RuleMark(x: .value("λ_max", lmax))
                    .foregroundStyle(.purple)
                    .lineStyle(.init(lineWidth: 1.5, dash: [2, 2]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("λ_max=\(String(format: "%.3f", lmax))")
                            .font(.caption2.bold()).foregroundStyle(.purple)
                    }
            }
        }
        .chartXAxisLabel("eigenvalue λ")
        .chartYAxisLabel("count")
        .frame(minHeight: 320)
    }

    @ViewBuilder
    private var statsRow: some View {
        let zt = max(1e-8, (eigs.max() ?? 0) * 1e-6)
        let nz = eigs.filter { $0 > zt }
        let nzCount = nz.count
        let zeroCount = eigs.count - nzCount
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                MetricBadge(label: "λ smallest", value: String(format: "%.4g", eigs.min() ?? 0),
                             systemImage: "arrowtriangle.down.fill", tint: .gray)
                MetricBadge(label: "λ_min (>0)", value: String(format: "%.4f", nz.min() ?? 0),
                             systemImage: "arrowtriangle.down", tint: .green)
                MetricBadge(label: "λ_max", value: String(format: "%.4f", nz.max() ?? 0),
                             systemImage: "arrowtriangle.up", tint: .purple)
                MetricBadge(label: "mean λ (>0)",
                             value: nzCount > 0
                                ? String(format: "%.4f", nz.reduce(0, +) / Double(nzCount))
                                : "—",
                             systemImage: "function", tint: .green)
                MetricBadge(label: "zeros dropped", value: "\(zeroCount)",
                             systemImage: "trash", tint: .gray)
                MetricBadge(label: "elapsed", value: String(format: "%.2f s", elapsed),
                             systemImage: "clock", tint: Palette.accent)
            }
        }
    }

    @ViewBuilder
    private var supportRow: some View {
        let y = Double(pRows) / Double(nSamples)
        let s = SpectralDensity.support(a: a, beta: beta, y: y, sigma2: 1.0)
        let caseColor: Color = s.caseLabel == 2 ? .orange : (s.caseLabel == 3 ? .purple : Palette.accent)
        HStack(spacing: 10) {
            Pill(text: "Case \(s.caseLabel)", color: caseColor, systemImage: "number.circle.fill")
            Pill(text: "z ∈ [\(String(format: "%.4f", s.lowerEdge)), \(String(format: "%.4f", s.upperEdge))]",
                 color: Palette.accent, systemImage: "ruler")
            if let g = s.interval2 {
                Pill(text: "gap (\(String(format: "%.4f", g.0)), \(String(format: "%.4f", g.1)))",
                     color: .red, systemImage: "scissors")
            }
            Spacer()
        }
    }

    // ---------- compute --------------------------------------------------

    private func generate() {
        running = true
        progressFraction = 0
        progressStage = "Starting…"
        let p = pRows, n = nSamples, beta_ = beta, a_ = a, s_ = seed
        let cpuOnly = !useGPU
        Task.detached {
            let r = SpikedSimulation.eigenvalues(p: p, n: n, a: a_, beta: beta_,
                                                  seed: s_, forceCPU: cpuOnly,
                                                  progress: { frac, stage in
                Task { @MainActor in
                    self.progressFraction = frac
                    self.progressStage = stage
                }
            })
            await MainActor.run {
                self.eigs = r.eigenvalues
                self.elapsed = r.elapsedSec
                self.deviceUsed = r.device
                self.running = false
                self.progressFraction = 1.0
                self.progressStage = "Done"
            }
        }
    }

    /// Public link to the research paper that derives the Gen-Cov method
    /// and the closed-form spectral density used here.
    static let researchPaperURL = URL(string:
        "https://yu314-coder.github.io/assets/docs/yau-science-award-research-paper.pdf")!

    private var researchPaperLink: some View {
        Link(destination: Self.researchPaperURL) {
            Label("Research paper (PDF)", systemImage: "doc.richtext.fill")
                .font(.caption.bold())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var paperBlurb: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap.fill").foregroundStyle(Palette.accent)
            Text("The closed-form density F_{y,H}(z) and Case 1/2/3 support analysis used above are derived in:")
                .font(.caption2).foregroundStyle(Palette.muted)
            Link("Yu (2025) — Geometric Analysis of the Eigenvalue Range of the Generalized Covariance Matrix",
                  destination: Self.researchPaperURL)
                .font(.caption2.bold())
                .foregroundStyle(Palette.accent)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if running || (progressFraction > 0 && progressFraction < 1) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, isActive: running)
                        .foregroundStyle(Palette.accent)
                    Text(progressStage)
                        .font(.caption.bold())
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Text("\(Int(progressFraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.muted)
                }
                ProgressView(value: progressFraction).progressViewStyle(.linear).tint(Palette.accent)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                    .fill(Color(white: 0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                    .stroke(Palette.accent.opacity(0.4), lineWidth: 0.8)
            )
        }
    }

    private struct DensityPt: Identifiable { let id = UUID(); let z: Double; let v: Double }
    private struct Bin: Identifiable { let id = UUID(); let center: Double; let count: Int }
    private func histogram(_ v: [Double], bins: Int) -> [Bin] {
        guard !v.isEmpty, bins > 1 else { return [] }
        let lo = v.min()!, hi = v.max()!
        let range = max(hi - lo, 1e-12)
        let dx = range / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for x in v {
            let idx = min(bins - 1, max(0, Int(floor((x - lo) / dx))))
            counts[idx] += 1
        }
        return (0..<bins).map { i in
            Bin(center: lo + (Double(i) + 0.5) * dx, count: counts[i])
        }
    }
}
