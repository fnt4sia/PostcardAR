//
//  PostcardARView.swift
//  PostcardAR
//

import ARKit
import RealityKit
import SwiftUI

/// Name of the AR Resource Group inside Assets.xcassets.
private let resourceGroupName = "AR Resources"

/// Name of the reference image inside that group.
private let referenceImageName = "postcard"

/// Name of the .usdz file in the app bundle, without the extension.
private let modelName = "postcard"

/// How wide the model should be, as a fraction of the postcard's width.
/// 1.0 makes it exactly as wide as the card. This is the only dial to turn for
/// model size — the .usdz can be authored at any scale.
private let modelWidthRelativeToCard: Float = 1.0

/// What the AR session is currently doing, so the UI can report it.
/// Image tracking and model loading are tracked separately, because when nothing
/// shows up on screen the first question is always which of the two failed.
@Observable
final class ARStatus {
    var isImageDetected = false
    var isModelLoaded = false
    var errorMessage: String?
}

/// Camera view that tracks the postcard image and shows a 3D model on top of it.
struct PostcardARView: UIViewRepresentable {
    let status: ARStatus

    func makeCoordinator() -> Coordinator {
        Coordinator(status: status)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

        guard ARImageTrackingConfiguration.isSupported else {
            status.errorMessage = "Image tracking needs a real device, not the simulator."
            return arView
        }

        let referenceImages = ARReferenceImage.referenceImages(
            inGroupNamed: resourceGroupName,
            bundle: nil
        ) ?? []

        arView.session.delegate = context.coordinator
        arView.session.run(makeConfiguration(with: referenceImages))

        let cardWidth = referenceImages.first { $0.name == referenceImageName }?.physicalSize.width
        arView.scene.addAnchor(makeAnchor(cardWidth: Float(cardWidth ?? 0)))

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    private func makeConfiguration(
        with referenceImages: Set<ARReferenceImage>
    ) -> ARImageTrackingConfiguration {
        let configuration = ARImageTrackingConfiguration()
        configuration.trackingImages = referenceImages
        configuration.maximumNumberOfTrackedImages = 1
        return configuration
    }

    private func makeAnchor(cardWidth: Float) -> AnchorEntity {
        // ARKit rewrites this anchor's transform every frame from the tracked image's
        // pose, so the model inherits the card's position and rotation for free.
        let anchor = AnchorEntity(.image(group: resourceGroupName, name: referenceImageName))

        Task { @MainActor in
            do {
                let model = try await Entity(named: modelName)
                fit(model, toCardWidth: cardWidth)
                anchor.addChild(model)
                status.isModelLoaded = true
            } catch {
                status.errorMessage = "Could not load \(modelName).usdz: \(error.localizedDescription)"
            }
        }

        return anchor
    }

    /// Scales the model so its width is a fixed fraction of the card's width, then sits it
    /// centred on the card with its base on the card's surface.
    ///
    /// Without this the model renders at whatever real-world size the .usdz was authored at,
    /// which has nothing to do with how big the postcard is. Deriving the scale from the card
    /// instead means the model always looks right relative to the card, whatever units the
    /// model was exported in.
    private func fit(_ model: Entity, toCardWidth cardWidth: Float) {
        // The anchor's local axes follow the image: x across its width, z down its height,
        // y pointing out of the card's surface.
        let bounds = model.visualBounds(relativeTo: nil)
        guard cardWidth > 0, bounds.extents.x > 0 else { return }

        let scale = cardWidth * modelWidthRelativeToCard / bounds.extents.x
        model.scale = .init(repeating: scale)

        // The .usdz origin is wherever the artist left it, so offset by the measured centre
        // rather than assuming it is already centred.
        model.position = [
            -bounds.center.x * scale,
            (bounds.extents.y / 2 - bounds.center.y) * scale,
            -bounds.center.z * scale
        ]
    }

    /// Reports image tracking state back to the UI.
    /// ARKit calls these on the main thread because `session.delegateQueue` is left nil.
    final class Coordinator: NSObject, ARSessionDelegate {
        private let status: ARStatus

        init(status: ARStatus) {
            self.status = status
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            updateDetection(from: anchors)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            updateDetection(from: anchors)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            status.isImageDetected = false
        }

        func session(_ session: ARSession, didFailWithError error: any Error) {
            status.errorMessage = error.localizedDescription
        }

        private func updateDetection(from anchors: [ARAnchor]) {
            guard let imageAnchor = anchors.compactMap({ $0 as? ARImageAnchor }).first else { return }
            status.isImageDetected = imageAnchor.isTracked
        }
    }
}
