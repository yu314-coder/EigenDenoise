//
//  DenoiseView.swift
//  Image-Processing tab — runs both classical M-P and the rmt-denoise
//  generalized-covariance oracle on the same noisy stack, displays the
//  4-image grid (Clean / Noisy / M-P / Gen-Cov), per-method PSNR & rank
//  badges, and a top-eigenvalue chart of the centred noisy stack.
//

import AppKit
import Charts
import SwiftUI

struct DenoiseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EmptyView().onAppear {
                EDLog.log(.ui, "DenoiseView appear — imageCount=\(model.imageCount) test='\(model.testFilename)' lastResult=\(model.lastBridgeResult != nil)")
            }
            SectionHeading(title: "Image processing",
                            systemImage: "wand.and.stars",
                            subtitle: "Classical M-P baseline + generalized-covariance oracle (rmt-denoise) on the same noisy stack")

            ControlPlotLayout(
                controls: { controlsCard },
                plots: { plotsCard }
            )
        }
    }

    // MARK: - Controls (left sidebar)

    private var controlsCard: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: 14) {
            folderCard
            Card(title: "Test image", systemImage: "scope") {
                if model.imageNames.isEmpty {
                    Text("No images loaded — pick a folder above (or download a dataset on the Datasets tab).")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                } else {
                    Picker("", selection: $m.testFilename) {
                        ForEach(model.imageNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    HStack(spacing: 6) {
                        Pill(text: "\(model.imageCount) images",
                             color: Palette.accent, systemImage: "rectangle.stack")
                        Pill(text: "\(model.imageH)×\(model.imageW)",
                             color: .gray, systemImage: "ruler")
                    }
                    miniGrid
                }
            }
            Card(title: "Method", systemImage: "slider.horizontal.3") {
                Picker("", selection: $m.runMethod) {
                    ForEach(DenoiseRunMethod.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Card(title: "Run parameters", systemImage: "dial.high") {
                InlineField(label: "Train images", value: $m.nTrain)
                LabeledContent("Device") {
                    Picker("", selection: $m.device) {
                        Text("auto").tag("auto")
                        Text("cpu").tag("cpu")
                        Text("mps").tag("mps")
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            Card(title: "Post-processing", systemImage: "wand.and.rays") {
                Toggle(isOn: $m.applyT) {
                    HStack(spacing: 4) {
                        Image(systemName: "function")
                        Text("Apply T(a, β)")
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $m.colorResize) {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                        Text("Color resize")
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $m.center) {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                        Text("Center: X̃ = X − X̄")
                    }
                }
                .toggleStyle(.switch)
                Text("Each toggle maps directly to a constructor flag on rmt-denoise's GeneralizedCovDenoiser (≥ 2.3.0).")
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
            }
            noiseCard
            Button {
                model.runDenoiseViaBridge()
            } label: {
                HStack {
                    Image(systemName: model.isDenoising ? "arrow.triangle.2.circlepath" : "play.fill")
                        .symbolEffect(.pulse, isActive: model.isDenoising)
                    Text(model.isDenoising ? "Running…" : "Denoise")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isDenoising || model.imageCount < 2 || model.testFilename.isEmpty)
        }
    }

    @ViewBuilder
    private var noiseCard: some View {
        @Bindable var m = model
        let cfg = m.noiseConfig
        let header = AnyView(
            Toggle("Add noise", isOn: $m.noiseConfig.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        )
        Card(title: "Noise injection", systemImage: "waveform.path",
              trailing: header) {
            if !cfg.enabled {
                Text("Noise injection is disabled — the bridge will pass the clean stack through unchanged.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            } else {
                Picker("Type", selection: $m.noiseConfig.kind) {
                    ForEach(NoiseKind.allCases) { k in Text(k.label).tag(k) }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                switch cfg.kind {
                case .gaussian:
                    HStack(spacing: 10) {
                        InlineField(label: "σ", value: $m.noiseConfig.sigma, width: 70)
                        InlineField(label: "μ", value: $m.noiseConfig.mu,    width: 70)
                    }
                    Text("σ, μ are in [0, 255]; the bridge divides by 255 before injection. Same units as /Volumes/D/denoise/app.py.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                case .mog:
                    Text("Mixture of two Gaussians (per-pixel pick)").font(.caption.bold()).foregroundStyle(Palette.muted)
                    HStack(spacing: 8) {
                        InlineField(label: "G1 σ", value: $m.noiseConfig.mogSigma1, width: 60)
                        InlineField(label: "G1 μ", value: $m.noiseConfig.mogMu1,    width: 60)
                        InlineField(label: "w1",   value: $m.noiseConfig.mogW1,     width: 60)
                    }
                    HStack(spacing: 8) {
                        InlineField(label: "G2 σ", value: $m.noiseConfig.mogSigma2, width: 60)
                        InlineField(label: "G2 μ", value: $m.noiseConfig.mogMu2,    width: 60)
                    }
                case .twoPoint:
                    Text("H = β·δ₁ + (1-β)·δ_a").font(.caption.bold()).foregroundStyle(Palette.muted)
                    HStack(spacing: 10) {
                        InlineField(label: "σ",  value: $m.noiseConfig.tpSigma, width: 60)
                        InlineField(label: "a",  value: $m.noiseConfig.tpA,     width: 60)
                        InlineField(label: "β",  value: $m.noiseConfig.tpBeta,  width: 60)
                    }
                case .halfGaussian:
                    HStack(spacing: 10) {
                        InlineField(label: "σ", value: $m.noiseConfig.hgSigma, width: 70)
                        InlineField(label: "μ", value: $m.noiseConfig.hgMu,    width: 70)
                    }
                    Text("Random 50 % of the (p × n) matrix entries get N(μ, σ²) noise; the rest stay clean.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                case .blockHalf:
                    HStack(spacing: 10) {
                        InlineField(label: "σ", value: $m.noiseConfig.bhSigma, width: 70)
                        InlineField(label: "μ", value: $m.noiseConfig.bhMu,    width: 70)
                    }
                    Text("Top-left X[0:p/2, 0:n/2] block gets full Gaussian noise; the rest of the matrix stays clean.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                }
            }
            InlineField(label: "Seed", value: $m.noiseSeed)
        }
    }

    private var folderCard: some View {
        @Bindable var m = model
        return Card(title: "Folder", systemImage: "folder.fill",
                     trailing: AnyView(
                        Button {
                            model.pickFolder()
                        } label: { Label("Browse…", systemImage: "tray.and.arrow.down") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                     )
        ) {
            if let url = model.folderURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text(url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2).truncationMode(.middle)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.folder").foregroundStyle(.orange)
                    Text("No folder selected. Browse… or download a dataset on the Datasets tab.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("H").font(.caption2).foregroundStyle(Palette.muted)
                    TextField("", value: $m.resizeH, format: .number).frame(width: 56).subtleField()
                }
                HStack(spacing: 4) {
                    Text("W").font(.caption2).foregroundStyle(Palette.muted)
                    TextField("", value: $m.resizeW, format: .number).frame(width: 56).subtleField()
                }
                Spacer()
                Button {
                    if let u = model.folderURL { model.loadFolder(u) }
                } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.folderURL == nil)
            }
            if !model.folderSubfolders.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Sub-folders").font(.caption2.bold()).foregroundStyle(Palette.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(model.folderSubfolders, id: \.path) { url in
                        let active = model.folderURL?.path == url.path
                        Button {
                            model.loadFolder(url)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: active ? "folder.fill.badge.checkmark" : "folder.fill")
                                    .foregroundStyle(active ? Palette.accent : .secondary)
                                Text(url.lastPathComponent).font(.caption).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(active ? Palette.accent.opacity(0.18) : Color(white: 0.97))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(active ? Palette.accent : Palette.border,
                                            lineWidth: active ? 1.0 : 0.5)
                            )
                            .foregroundStyle(Palette.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var miniGrid: some View {
        let names = Array(model.imageNames.prefix(36))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4)],
                         spacing: 4) {
            ForEach(names, id: \.self) { name in
                let p = model.imageH * model.imageW
                let idx = model.imageNames.firstIndex(of: name) ?? 0
                let slice: [Float] = idx * p + p <= model.imageData.count
                    ? Array(model.imageData[(idx * p) ..< ((idx + 1) * p)]) : []
                let isSel = model.testFilename == name
                ZStack {
                    if !slice.isEmpty,
                       let img = ImageIO.nsImage(slice, H: model.imageH, W: model.imageW) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Color(white: 0.94).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSel ? Palette.accent : Palette.border,
                                lineWidth: isSel ? 2.0 : 0.5)
                )
                .onTapGesture { model.testFilename = name }
            }
        }
    }

    // MARK: - Plot column (right)

    @ViewBuilder
    private var plotsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow
            if let r = model.lastBridgeResult {
                metricsCard(r)
                imagesCard
                eigenvaluesCard(r)
            } else {
                Card(title: "Get started", systemImage: "info.circle") {
                    Text("Pick a test image, choose a method, click **Denoise**. The classical M-P and generalized-covariance (rmt-denoise) outputs will appear side-by-side with their PSNR and chosen rank.")
                        .foregroundStyle(Palette.text)
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            if model.isDenoising {
                StatusBadge(kind: .running, text: "rmt-denoise running")
            } else if model.lastBridgeResult != nil {
                StatusBadge(kind: .ok, text: "ready")
            } else {
                StatusBadge(kind: .idle, text: "idle")
            }
            if let r = model.lastBridgeResult {
                Pill(text: "rmt-denoise \(r.rmtDenoiseVersion)",
                     color: Palette.accent, systemImage: "shippingbox")
                Pill(text: r.device,
                     color: r.device == "mps" ? .purple : .gray,
                     systemImage: "cpu.fill")
                Pill(text: "y = \(String(format: "%.2f", r.y))",
                     color: .gray, systemImage: "function")
                Pill(text: String(format: "elapsed %.2fs", r.elapsed),
                     color: .gray, systemImage: "clock")
            }
            Spacer()
            if let dir = model.bridgeOutputDir {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                } label: { Label("Reveal output", systemImage: "folder") }
                .buttonStyle(.bordered)
            }
        }
    }

    private func metricsCard(_ r: RMTBridgeResult) -> some View {
        Card(title: "Metrics", systemImage: "checkmark.seal.fill") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    MetricBadge(label: "PSNR — M-P (dB)",
                                 value: r.psnrMP.isFinite ? String(format: "%.3f", r.psnrMP) : "—",
                                 systemImage: "waveform.path", tint: .blue)
                    MetricBadge(label: "PSNR — Gen-Cov (dB)",
                                 value: r.psnrGen.isFinite ? String(format: "%.3f", r.psnrGen) : "—",
                                 systemImage: "waveform.path", tint: .green)
                    MetricBadge(label: "ΔPSNR (Gen − MP)",
                                 value: (r.psnrGen.isFinite && r.psnrMP.isFinite)
                                        ? String(format: "%+.3f", r.psnrGen - r.psnrMP)
                                        : "—",
                                 systemImage: "plus.forwardslash.minus",
                                 tint: r.psnrGen >= r.psnrMP ? .green : .red)
                    MetricBadge(label: "elapsed",
                                 value: String(format: "%.2f s", r.elapsed),
                                 systemImage: "clock", tint: Palette.accent)
                }
                GridRow {
                    MetricBadge(label: "rank — M-P",
                                 value: "\(r.rankMP)",
                                 systemImage: "ruler", tint: .blue)
                    MetricBadge(label: "rank — Gen-Cov",
                                 value: "\(r.rankGen)",
                                 systemImage: "ruler", tint: .green)
                    MetricBadge(label: "â",
                                 value: r.a.isFinite ? String(format: "%.4f", r.a) : "—",
                                 systemImage: "a.circle", tint: .pink)
                    MetricBadge(label: "β̂",
                                 value: r.beta.isFinite ? String(format: "%.4f", r.beta) : "—",
                                 systemImage: "b.circle", tint: .purple)
                }
            }
        }
    }

    private var imagesCard: some View {
        Card(title: "Images", systemImage: "photo.on.rectangle.angled") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ImageTile(title: "Original (clean)", image: model.bridgeCleanImage)
                ImageTile(title: "Noisy",            image: model.bridgeNoisyImage)
                ImageTile(title: "M-P denoised",     image: model.bridgeMPImage)
                ImageTile(title: "Gen-Cov denoised — rmt-denoise", image: model.bridgeGenImage)
            }
        }
    }

    private func eigenvaluesCard(_ r: RMTBridgeResult) -> some View {
        struct Pt: Identifiable { let id = UUID(); let i: Int; let v: Double }
        let pts: [Pt] = r.eigenvalues.enumerated().map { Pt(i: $0.offset + 1, v: $0.element) }
        let lamMP  = (r.rankMP > 0 && r.rankMP <= r.eigenvalues.count) ? r.eigenvalues[r.rankMP - 1] : nil
        let lamGen = (r.rankGen > 0 && r.rankGen <= r.eigenvalues.count) ? r.eigenvalues[r.rankGen - 1] : nil
        EDLog.log(.ui, "eigenvaluesCard render — eigs=\(r.eigenvalues.count) rankMP=\(r.rankMP) rankGen=\(r.rankGen) lamMP=\(lamMP.map { String(format: "%.3g", $0) } ?? "nil") lamGen=\(lamGen.map { String(format: "%.3g", $0) } ?? "nil")")
        return Card(title: "Top eigenvalues of the noisy stack",
                     systemImage: "chart.bar",
                     trailing: AnyView(
                        Pill(text: "centred  λ = σ²/n",
                             color: .gray, systemImage: "function")
                     )
        ) {
            Chart {
                ForEach(pts) { p in
                    BarMark(x: .value("rank i", p.i), y: .value("λ", p.v))
                        .foregroundStyle(LinearGradient(colors: [Palette.accent, Palette.accent2],
                                                         startPoint: .top, endPoint: .bottom))
                        .opacity(0.85)
                }
                if let lam = lamMP {
                    RuleMark(y: .value("MP cutoff", lam))
                        .foregroundStyle(.blue)
                        .lineStyle(.init(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("MP r̂ = \(r.rankMP)")
                                .font(.caption2.bold()).foregroundStyle(.blue)
                        }
                }
                if let lam = lamGen {
                    RuleMark(y: .value("Gen cutoff", lam))
                        .foregroundStyle(.green)
                        .lineStyle(.init(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Gen r̂ = \(r.rankGen)")
                                .font(.caption2.bold()).foregroundStyle(.green)
                        }
                }
            }
            .chartXAxisLabel("eigenvalue index i")
            .chartYAxisLabel("λᵢ")
            // NOTE: do NOT use .chartYScale(type: .log) here — BarMark needs a
            // zero baseline and log(0) is undefined → Swift Charts trips an
            // internal precondition (manifests as EXC_BREAKPOINT). Linear is fine.
            .frame(minHeight: 260)
            Text("Bars are the top 60 eigenvalues of the centred noisy stack (1/n) X̃ X̃ᵀ. Dashed rules mark the rank cutoffs each method picked: M-P keeps the top \(r.rankMP) components (above the array length here, so MP rule is hidden); Gen-Cov keeps \(r.rankGen).")
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
    }
}
