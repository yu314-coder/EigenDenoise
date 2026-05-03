//
//  ContentView.swift
//  Top-level shell — delegates to the multi-tab MainTabView.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MainTabView()
    }
}

#Preview {
    ContentView()
        .environment(AppModel.shared)
        .frame(width: 1100, height: 720)
}
