//
//  ContentView.swift
//  PostcardAR
//
//  Created by Fitra Ramadhan on 15/08/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isScanning = false

    var body: some View {
        Button("Start Scanning") {
            isScanning = true
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fullScreenCover(isPresented: $isScanning) {
            ScannerScreen()
        }
    }
}

/// The camera screen, plus an overlay saying whether the postcard is currently detected.
private struct ScannerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = ARStatus()

    var body: some View {
        PostcardARView(status: status)
            .ignoresSafeArea()
            .overlay(alignment: .top) { statusPanel }
            .overlay(alignment: .bottom) {
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                status.isImageDetected ? "Postcard detected" : "Looking for postcard…",
                systemImage: status.isImageDetected ? "checkmark.circle.fill" : "viewfinder"
            )
            .foregroundStyle(status.isImageDetected ? .green : .white)

            Label(
                status.isModelLoaded ? "Model loaded" : "Loading model…",
                systemImage: status.isModelLoaded ? "checkmark.circle.fill" : "clock"
            )
            .foregroundStyle(status.isModelLoaded ? .green : .white)

            if let errorMessage = status.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
        .padding()
    }
}

#Preview {
    ContentView()
}
