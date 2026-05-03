//
//  MainTabView.swift
//  Replicates the random_matrix_ESD HTML layout in SwiftUI:
//  sticky header with brand → horizontal tab bar → white cards on a dark
//  navy radial-gradient background.
//

import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    // Default to Im(s) vs z to mirror the GitHub repo's HTML
    // (`<div class="tab active" data-tab="tab-im">`).
    @State private var selection: Tab = .imSvsZ

    enum Tab: String, CaseIterable, Identifiable {
        case imSvsZ, rootsBeta, eigenvalues, folders, denoise, log
        var id: String { rawValue }
        var label: String {
            switch self {
            case .imSvsZ:      return "Im(s) vs z"
            case .rootsBeta:   return "Roots vs β"
            case .eigenvalues: return "Eigenvalue distribution"
            case .folders:     return "Datasets"
            case .denoise:     return "Image Processing"
            case .log:         return "Output"
            }
        }
        var icon: String {
            switch self {
            case .imSvsZ:      return "function"
            case .rootsBeta:   return "chart.line.uptrend.xyaxis"
            case .eigenvalues: return "chart.bar.fill"
            case .folders:     return "externaldrive.fill"
            case .denoise:     return "wand.and.stars"
            case .log:         return "doc.text"
            }
        }
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                AppHeader(
                    title: "Matrix Analysis Lab — EigenDenoise",
                    subtitle: "Random matrix theory · denoising · spectral analysis"
                )
                .environment(\.colorScheme, .dark)   // <- only the dark bar uses dark scheme
                TabBar(tabs: Tab.allCases,
                       label: { $0.label },
                       icon: { $0.icon },
                       selection: $selection)
                .environment(\.colorScheme, .dark)   // <- tab pills sit on the dark bg
                ScrollView {
                    Group {
                        switch selection {
                        case .folders:     FolderView()
                        case .denoise:     DenoiseView()
                        case .eigenvalues: EigenvalueView()
                        case .imSvsZ:      ImSvsZView()
                        case .rootsBeta:   RootsView()
                        case .log:         LogView()
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(24)
                    .frame(maxWidth: 1300, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .onChange(of: selection) { _, t in
                    EDLog.log(.ui, "tab changed → \(t.label)")
                }
                .onAppear {
                    EDLog.log(.ui, "MainTabView appeared, default tab=\(selection.label)")
                }
            }
        }
    }
}

// MARK: - Log tab styled like the rest

struct LogView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Card(title: "Backend log", systemImage: "list.bullet.clipboard",
              trailing: AnyView(
                HStack(spacing: 6) {
                    Button("Clear") { model.clearLog() }.buttonStyle(.bordered)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.logLines.joined(separator: "\n"),
                                                       forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                }
              )
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(colorFor(line))
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(minHeight: 360)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                        .fill(Color(white: 0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                        .stroke(Palette.border, lineWidth: 0.5)
                )
                .onChange(of: model.logLines.count) { _, n in
                    if n > 0 {
                        withAnimation(.linear(duration: 0.05)) {
                            proxy.scrollTo(n - 1, anchor: .bottom)
                        }
                    }
                }
            }
            HStack {
                Text("\(model.logLines.count) lines")
                    .font(.caption).foregroundStyle(Palette.muted)
                Spacer()
            }
        }
    }

    private func colorFor(_ line: String) -> Color {
        if line.contains("error") || line.contains("Error")    { return .red }
        if line.contains("[py-err]") || line.contains("Traceback") { return .red }
        if line.contains("PSNR") || line.contains("done")       { return .green }
        if line.contains("[py]")                                { return Palette.accent }
        return Palette.text
    }
}
