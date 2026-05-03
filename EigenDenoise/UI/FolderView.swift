//
//  FolderView.swift
//  Pick a folder, choose a test image — modern dataset-gallery layout.
//

import SwiftUI

// MARK: - Preset descriptors

private struct DatasetPreset: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
    let blurb: String
    let systemImage: String
    let tint: Color
    let load: () -> Void
}

struct FolderView: View {
    @Environment(AppModel.self) private var model

    @State private var downloadURLs: String = ""
    @State private var downloadSubfolder: String = "downloaded"
    @State private var deselectedURLs: Set<String> = []
    @State private var advancedURLsExpanded: Bool = false
    @State private var activePresetID: UUID? = nil

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 16) {
            EmptyView().onAppear { EDLog.log(.ui, "FolderView appear — imageCount=\(model.imageCount)") }
            SectionHeading(title: "Datasets & storage",
                            systemImage: "externaldrive.fill",
                            subtitle: "Download curated image datasets and pick where they're saved. Folder & test-image selection lives in Image Processing.")

            heroStatusCard
            storageCard
            datasetGalleryCard
        }
    }

    // MARK: - Hero status

    private var heroStatusCard: some View {
        let hasFolder = model.folderURL != nil
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.accent, Palette.accent2],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: hasFolder ? "checkmark.circle.fill" : "photo.stack")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(hasFolder ? (model.folderURL?.lastPathComponent ?? "—") : "No folder loaded")
                    .font(.title3.bold())
                    .foregroundStyle(Palette.text)
                Text(hasFolder
                    ? (model.folderURL?.deletingLastPathComponent().path ?? "")
                    : "Pick a folder or download a curated dataset to begin.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 10) {
                heroStat(value: "\(model.imageCount)",  label: "images",
                         systemImage: "photo.stack",      tint: Palette.accent)
                heroStat(value: model.imageCount == 0 ? "—" : "\(model.imageH)×\(model.imageW)",
                         label: "size",                   systemImage: "ruler",
                         tint: .indigo)
                heroStat(value: "\(model.folderSubfolders.count)",
                         label: "subfolders",             systemImage: "books.vertical",
                         tint: .orange)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerLg, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLg, style: .continuous)
                .stroke(Palette.border, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private func heroStat(value: String, label: String,
                           systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.caption2).foregroundStyle(tint)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Palette.muted)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
        }
        .frame(minWidth: 78, alignment: .leading)
    }

    // MARK: - Storage card

    private var storageCard: some View {
        Card(title: "Storage location",
              systemImage: "externaldrive.fill",
              trailing: AnyView(
                HStack(spacing: 6) {
                    Button { model.pickStorageLocation() } label: {
                        Label("Change…", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                    Button { model.resetStorageToDefault() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
              )
        ) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full").foregroundStyle(Palette.accent)
                Text(model.storageURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(Palette.text)
                    .lineLimit(2).truncationMode(.middle)
            }
            Text("All downloaded datasets are saved here. Default is your sandboxed Application Support folder. Pick any local folder — the choice persists via a security-scoped bookmark.")
                .font(.caption2).foregroundStyle(Palette.muted)
        }
    }

    // MARK: - Dataset gallery (modern download card)

    private var presets: [DatasetPreset] {
        [
            .init(name: "ORL Faces", count: 400,
                  blurb: "AT&T grayscale 92×112 PGMs · 40 subjects × 10 poses",
                  systemImage: "person.crop.square.fill",
                  tint: .blue) {
                downloadURLs = orlSampleURLs
                downloadSubfolder = "orl_faces"
                deselectedURLs.removeAll()
            },
            .init(name: "CBSD68", count: 68,
                  blurb: "Color Berkeley test set · classic denoise benchmark",
                  systemImage: "photo.on.rectangle.angled",
                  tint: .green) {
                downloadURLs = cbsdSampleURLs
                downloadSubfolder = "cbsd68"
                deselectedURLs.removeAll()
            },
            .init(name: "Brain MRI", count: 3264,
                  blurb: "T1 axial slices · 4 tumor classes · live GitHub listing",
                  systemImage: "brain.head.profile",
                  tint: .purple) {
                let cls = ["glioma_tumor", "meningioma_tumor", "no_tumor", "pituitary_tumor"]
                let paths = cls.flatMap { ["Training/\($0)", "Testing/\($0)"] }
                loadPresetFromGitHubAPI(owner: "sartajbhuvaji",
                                          repo: "brain-tumor-classification-dataset",
                                          paths: paths,
                                          subfolder: "mri")
            }
        ]
    }

    private var datasetGalleryCard: some View {
        Card(title: "Download dataset",
              systemImage: "square.and.arrow.down.on.square.fill",
              trailing: AnyView(
                Pill(text: "\(urlsParsed.count) URLs",
                     color: urlsParsed.isEmpty ? .gray : Palette.accent,
                     systemImage: "link")
              )
        ) {
            Text("Pick a curated dataset, or paste your own URLs. Files save to **Storage / sub-folder** and auto-load when complete.")
                .font(.caption).foregroundStyle(Palette.muted)

            // Modern preset gallery — 3 large cards.
            HStack(spacing: 10) {
                ForEach(presets) { preset in
                    presetTile(preset)
                }
            }

            Divider().padding(.vertical, 4)

            // Sub-folder + destination preview.
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus").foregroundStyle(Palette.accent)
                Text("Sub-folder").font(.caption.bold()).foregroundStyle(Palette.muted)
                TextField("name", text: $downloadSubfolder)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(Palette.muted).font(.caption2)
                Text(destinationFolder.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }

            // Custom URLs (collapsible).
            DisclosureGroup(isExpanded: $advancedURLsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One URL per line · # for comments. Edits sync with the preview list below.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                    TextEditor(text: $downloadURLs)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 90)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                                .fill(Color(white: 0.97))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                                .stroke(Palette.border, lineWidth: 0.5)
                        )
                    HStack {
                        Button("Clear") { downloadURLs = ""; deselectedURLs.removeAll(); activePresetID = nil }
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.alignleft").foregroundStyle(Palette.muted)
                    Text("Custom URLs").font(.caption.bold()).foregroundStyle(Palette.muted)
                }
            }

            // URL pick list (when there are URLs).
            if !urlsParsed.isEmpty {
                HStack(spacing: 8) {
                    Text("\(selectedURLs.count) of \(urlsParsed.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.text)
                    Spacer()
                    Button("All")  { deselectedURLs.removeAll() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("None") { deselectedURLs = Set(urlsParsed.map { $0.absoluteString }) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                urlPickList
            }

            // Action row.
            HStack(spacing: 10) {
                if model.isDownloading {
                    let p = model.downloadProgress
                    let frac = p.total > 0 ? Double(p.done) / Double(p.total) : 0
                    ProgressView(value: frac).progressViewStyle(.linear).frame(maxWidth: 240)
                    Text("\(p.done) / \(p.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button {
                    startDownload()
                } label: {
                    Label(model.isDownloading
                            ? "Downloading…"
                            : "Download \(selectedURLs.count) image\(selectedURLs.count == 1 ? "" : "s")",
                          systemImage: model.isDownloading
                            ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isDownloading || selectedURLs.isEmpty)
            }
        }
    }

    private func presetTile(_ preset: DatasetPreset) -> some View {
        let active = activePresetID == preset.id
        return Button {
            activePresetID = preset.id
            preset.load()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(preset.tint.opacity(0.18))
                        Image(systemName: preset.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(preset.tint)
                    }
                    .frame(width: 36, height: 36)
                    Spacer()
                    Text("\(preset.count)")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(preset.tint)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(
                            Capsule().fill(preset.tint.opacity(0.15))
                        )
                }
                Text(preset.name)
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                Text(preset.blurb)
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active
                          ? LinearGradient(colors: [preset.tint.opacity(0.18), preset.tint.opacity(0.06)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [Color(white: 0.99), Color(white: 0.96)],
                                            startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? preset.tint : Palette.border,
                            lineWidth: active ? 1.5 : 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    private var urlPickList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(urlsParsed.enumerated()), id: \.element.absoluteString) { (idx, url) in
                    let key = url.absoluteString
                    let isOn = !deselectedURLs.contains(key)
                    HStack(spacing: 10) {
                        Image(systemName: isOn ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isOn ? Palette.accent : Palette.muted)
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.text)
                            .frame(width: 180, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                        Text(url.absoluteString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(idx % 2 == 0 ? Color.clear : Color(white: 0.985))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isOn { deselectedURLs.insert(key) } else { deselectedURLs.remove(key) }
                    }
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 240)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                .fill(Color(white: 0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMd, style: .continuous)
                .stroke(Palette.border, lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private var urlsParsed: [URL] {
        downloadURLs
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0) }
    }

    private var selectedURLs: [URL] {
        urlsParsed.filter { !deselectedURLs.contains($0.absoluteString) }
    }

    private var destinationFolder: URL {
        let sub = downloadSubfolder.isEmpty ? "downloaded" : downloadSubfolder
        return model.storageURL.appendingPathComponent(sub, isDirectory: true)
    }

    private func startDownload() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let sub = downloadSubfolder.isEmpty ? "downloaded" : downloadSubfolder
        model.downloadImages(urls, subfolder: sub)
    }

    // MARK: - Preset URL builders

    private var orlSampleURLs: String {
        // Cambridge ORL/AT&T faces — full 40 subjects × 10 PGMs = 400 images,
        // mirrored in mims-harvard/nimfa.
        var lines: [String] = []
        for s in 1...40 {
            for i in 1...10 {
                lines.append("https://raw.githubusercontent.com/mims-harvard/nimfa/master/nimfa/datasets/ORL_faces/s\(s)/\(i).pgm")
            }
        }
        return lines.joined(separator: "\n")
    }
    private var cbsdSampleURLs: String {
        // CBSD68 — full 68-image colour Berkeley test set (PNG, indexed 0000..0067).
        (0...67).map {
            "https://raw.githubusercontent.com/clausmichele/CBSD68-dataset/master/CBSD68/original_png/\(String(format: "%04d", $0)).png"
        }.joined(separator: "\n")
    }

    /// Fetches the actual file listing of github folders via the contents
    /// API, picks images, and writes their raw URLs into the editor.
    private func loadPresetFromGitHubAPI(owner: String, repo: String,
                                          paths: [String], subfolder: String) {
        downloadSubfolder = subfolder
        downloadURLs = "# fetching listing from github.com…"
        deselectedURLs.removeAll()
        Task.detached {
            struct Item: Decodable { let name: String; let download_url: String? }
            let exts: Set<String> = ["jpg", "jpeg", "png", "bmp", "tif", "tiff", "gif", "pgm"]
            var allURLs: [String] = []
            do {
                for path in paths {
                    let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(path)")!
                    var req = URLRequest(url: api)
                    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let items = try JSONDecoder().decode([Item].self, from: data)
                    allURLs.append(contentsOf: items.compactMap { $0.download_url }
                        .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) })
                    await MainActor.run {
                        self.downloadURLs = "# fetched \(allURLs.count) so far (" + path + ")…"
                    }
                }
                let final = allURLs.sorted()
                await MainActor.run { self.downloadURLs = final.joined(separator: "\n") }
            } catch {
                await MainActor.run {
                    self.downloadURLs = "# failed to fetch listing: \(error.localizedDescription)"
                }
            }
        }
    }

}
