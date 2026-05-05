//
//  EigenDenoiseApp.swift
//  Native Swift port of the Matrix Analysis Lab + RMT-Denoise pipeline.
//

import AppKit
import SwiftUI

@main
struct EigenDenoiseApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("EigenDenoise") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    // Re-acquire previously-picked folder + storage location.
                    model.restoreStorageFromBookmark()
                    model.restoreFolderFromBookmark()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Open Folder…") { model.pickFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Run Denoise") { model.runDenoiseViaBridge() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Clear Log") { model.clearLog() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Open Research Paper (PDF)") {
                    if let url = URL(string:
                        "https://yu314-coder.github.io/assets/docs/yau-science-award-research-paper.pdf") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("EigenDenoise on GitHub") {
                    if let url = URL(string: "https://github.com/yu314-coder/EigenDenoise") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
