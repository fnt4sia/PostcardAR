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

/// The camera, full screen, with a status panel over it.
///
/// `status` is created here and handed down. It is the only channel out of the AR view: the
/// coordinator writes to it, and reading a property in `body` is what subscribes this view to
/// changes in that property.
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
            .overlay(alignment: .topLeading) {
                if let point = status.pinchPoint {
                    PinchCrosshair(progress: status.pinchProgress)
                        .position(point)
                }
            }
    }

    /// Detection and model loading are reported separately, because when nothing shows up the
    /// question is always which of the two failed. Both are counts now that the group can hold
    /// several cards: which ones are on camera, and how many of their models have arrived.
    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(!status.detectedImages.isEmpty,
                 done: "Detected: \(status.detectedImages.joined(separator: ", "))",
                 waiting: "Looking for a card…", icon: "viewfinder")

            line(status.totalImages > 0 && status.loadedModels == status.totalImages,
                 done: "Models loaded (\(status.loadedModels))",
                 waiting: "Loading models (\(status.loadedModels)/\(status.totalImages))…",
                 icon: "clock")

            ForEach(status.errors, id: \.self) { message in
                Text(message)
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

    private func line(_ isDone: Bool, done: String, waiting: String, icon: String) -> some View {
        Label(isDone ? done : waiting, systemImage: isDone ? "checkmark.circle.fill" : icon)
            .foregroundStyle(isDone ? Color.green : .white)
    }
}

/// Where the pinch is landing, and how closed it currently is.
private struct PinchCrosshair: View {
    let progress: Float

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.4), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)) // start the ring at 12 o'clock, fill clockwise
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
        }
        .frame(width: 44, height: 44)
        .animation(.easeOut(duration: 0.1), value: progress)
    }
}

#Preview {
    ContentView()
}
