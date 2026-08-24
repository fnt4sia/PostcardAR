//
//  ModelLibrary.swift
//  PostcardAR
//
//  Every card's reference image and model, loaded once and kept for the life of the app.
//
//  Two things used to happen inside `Coordinator.start(in:)`, which runs from
//  `UIViewRepresentable.makeUIView` — i.e. on the main thread, inside the presentation of the
//  camera screen:
//
//      1. `ARReferenceImage.referenceImages(inGroupNamed:)`, which decodes every card image in
//         the asset catalog and extracts its features. Synchronous, and the reason pressing
//         "Scan a Card" used to hang before the camera appeared.
//      2. One `Entity(named:)` per card.
//
//  Worse, `ScannerScreen` lives in a `fullScreenCover`: dismissing it destroyed the coordinator,
//  so **every** scan paid for both again. The fifth scan was as slow as the first.
//
//  Both now happen here instead, once, behind `LoadingView`, before the camera screen is built.
//  A second scan finds `isReady` already `true` and opens instantly.
//
//  `ContentView` owns one of these, above the `fullScreenCover` so it outlives it.
//

import ARKit
import RealityKit

/// The AR Resource Group in `Assets.xcassets`. Every reference image inside it is a card, and each
/// one shows the `.usdz` in the bundle carrying the same name — an image called `postcard` needs
/// `postcard.usdz`. Adding a card is those two files and nothing else; there is no list of names
/// in the code to keep in step.
///
/// Read here to load the images, and in `PostcardARView` to anchor to them by name.
let arResourceGroupName = "AR Resources"

/// Each card's model, sized to a fixed on-screen width in metres — deliberately independent of
/// the card's own printed width (`ARReferenceImage.physicalSize`, which ARKit tracks against), so
/// a small card can carry a large model and vice versa without the two fighting. The dial for
/// model size: `fit(_:named:)` measures the model at load time and makes its authored scale
/// irrelevant, so only these numbers matter. Keyed by card name; a card missing here falls back
/// to `defaultModelWidth`.
/// Keys are matched exactly, case included — a card renamed in the asset catalog and not renamed
/// here silently falls back to `defaultModelWidth`.
private let modelWidths: [String: Float] = [
    "Showcase_Biorock": 0.3,
    // Brought down from 0.3 when the shared seafloor came back. The floor is the card's own size —
    // 15.2 cm on a 6-inch card — so a model 30 cm wide overhung it by a factor of two and could not
    // read as standing *on* anything. Anything up to about 0.14 stays within its floor. A card whose
    // model ships its own ground (`Showcase_Biorock`) is not constrained this way.
    "Showcase_Coral": 0.12,
    "Showcase_Drupella": 0.08,
    "Simulation_Coral": 0.4,
    "Simulation_Drupella": 0.2,
]

/// Width a card without an entry in `modelWidths` is sized to.
private let defaultModelWidth: Float = 0.2

/// The shared ground plane laid under every card's model, from `Seafloor.usdz` in the bundle.
///
/// Deliberately not a card of its own: it has no reference image, is never in `models`, and is
/// loaded once and cloned per card by `seafloor(under:sizedTo:report:)`.
private let seafloorModelName = "Seafloor"

/// Ground geometry a card's *own* model already ships, named by the same idiom every other piece of
/// the content API uses. A model containing one of these gets no shared seafloor under it —
/// `Showcase_Biorock.usdz` has 115 `Seafloor_*` prims of its own, and stacking a second floor on
/// them only z-fights.
private let seafloorPrefix = "Seafloor"

/// The part of `Seafloor.usdz` that has to line up with the card.
///
/// A **prefix**, not an exact name, because the asset has been re-authored once already and renamed
/// this from `Seafloor_Sand` to `Seafloor_Sand_m` on the way. Measuring it rather than the whole
/// model matters: the pebbles and weeds scatter past the sand's edge, so sizing by the full
/// `visualBounds` would leave the sand itself smaller than the card.
private let seafloorSurfacePrefix = "Seafloor_Sand"

/// How far the **top of the sand** sits *above* the card plane, in metres — so the models, which
/// `fit(_:named:)` stands with their base at y = 0, are planted a little into the floor rather than
/// resting on its highest grain.
///
/// This is the number that fixes "the model looks like it is flying". It has to be positive. The
/// sand is a sculpted surface, not a flat one — about 4.6 mm of undulation once scaled to a 6-inch
/// card — so a model whose base sits exactly at the sand's *bounding-box top* touches only the
/// highest dune and visibly hovers over everything lower. Sinking it by roughly that undulation
/// puts the base near the average surface, and the contact reads as solid from every angle.
private let seafloorEmbed: Float = 0.004

/// The reference images and the prepared models, loaded once and reused by every scan.
@MainActor
@Observable
final class ModelLibrary {
    /// Everything is loaded and a camera screen can be built. `ContentView` shows `LoadingView`
    /// until this is true, and skips it entirely on the second scan.
    private(set) var isReady = false

    /// Models finished, out of `total` — what `LoadingView` draws its progress from.
    private(set) var loaded = 0
    private(set) var total = 0

    /// Collected rather than replaced: with several models, one missing `.usdz` must not hide the
    /// next. Drained by `Coordinator.start(in:)`, which runs after the library has loaded.
    private(set) var errors: [String] = []

    /// Sorted by name, so anchor order is stable between runs.
    @ObservationIgnored private(set) var referenceImages: [ARReferenceImage] = []

    /// Every model in the bundle, by name — one `.usdz` each, `Seafloor` excluded since it is
    /// ground rather than any card's model. Sorted, for the same reason as above.
    ///
    /// Scanned from the bundle rather than read off the reference images, which is the change a
    /// QR-named model forces: a model no longer needs a same-named reference image to exist, and
    /// a reference image no longer needs a same-named model. The two lists are now independent —
    /// images say *where* a card is, payloads say *what* is printed on it.
    @ObservationIgnored private(set) var modelNames: [String] = []

    /// The pristine model per card name — camera-stripped and scaled, never added to a scene.
    /// `model(named:)` hands out clones of these; see there for why.
    @ObservationIgnored private var models: [String: Entity] = [:]

    /// The pristine shared ground plane, camera-stripped but **not** scaled — it is sized per card
    /// by `seafloor(under:sizedTo:report:)`, since each card can be printed at a different size.
    /// `nil` if `Seafloor.usdz` is missing, which is not an error: models simply stand on the card.
    @ObservationIgnored private var seafloorModel: Entity?

    /// Guards against a second `load()` overlapping the first — the button can be pressed again
    /// while the loading screen is up.
    @ObservationIgnored private var isLoading = false

    /// Loads every card's reference image and model. Safe to call repeatedly: the second call
    /// returns immediately, which is what makes the second scan instant.
    func load() async {
        guard !isReady, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        referenceImages = await Self.loadReferenceImages()
        modelNames = Self.bundledModelNames()
        total = modelNames.count

        guard !referenceImages.isEmpty else {
            errors.append("No reference images in the \"\(arResourceGroupName)\" group.")
            isReady = true // nothing to wait for; the camera screen reports the problem
            return
        }

        // Before the cards, because every one of them may want a clone of it. Not counted in
        // `loaded`/`total`, which count *cards*; a missing `Seafloor.usdz` is silent, since a
        // project that does not ship one simply stands its models on the card itself.
        if Bundle.main.url(forResource: seafloorModelName, withExtension: "usdz") != nil {
            do {
                let floor = try await Entity(named: seafloorModelName)
                Self.removeCameras(from: floor)
                Self.removeImportedLighting(from: floor)
                seafloorModel = floor
            } catch {
                errors.append("Could not load \(seafloorModelName).usdz: \(error.localizedDescription)")
            }
        }

        // One at a time rather than all at once: decoding and texture upload happen on the main
        // thread either way, so overlapping them would only make a longer stall.
        for name in modelNames {
            do {
                let model = try await Entity(named: name)
                Self.removeCameras(from: model)
                Self.removeImportedLighting(from: model)
                fit(model, named: name)
                models[name] = model
            } catch {
                errors.append("Could not load \(name).usdz: \(error.localizedDescription)")
            }
            loaded += 1
        }

        isReady = true
    }

    /// Every `.usdz` in the bundle bar the shared seafloor, by basename.
    ///
    /// The bundle is the list because the naming convention is the content API: a `.usdz` dropped
    /// in is a model a QR can name, with no catalog entry and no code to keep in step.
    private static func bundledModelNames() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "usdz", subdirectory: nil) ?? []
        return urls
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != seafloorModelName }
            .sorted()
    }

    /// A fresh copy of one card's model, or `nil` if it failed to load.
    ///
    /// **A clone, not the model itself.** A scan mutates what it is given — corals get planted,
    /// snails hidden, annotation markers stripped — and `PinchInteraction` reads each piece's
    /// *current* transform as the `home` it restores to, so reusing one tree would record a planted
    /// coral's slot as its home. Clones share `MeshResource` and materials, so nothing is
    /// re-uploaded.
    func model(named name: String) -> Entity? {
        models[name]?.clone(recursive: true)
    }

    /// A ground plane sized to one card, to be added to that card's **pivot as a sibling of the
    /// model** — never as a child of it, or `fit(_:named:)`'s measurement of the model would include
    /// the floor and every card's model would come out the wrong size.
    ///
    /// `nil` when there is no `Seafloor.usdz`, or when `model` already ships ground of its own.
    ///
    /// **Sized to the card, not to `modelWidths`.** The opposite of the rule for models, and
    /// deliberately: a model's size is an artistic choice that must stay free of the card's printed
    /// size, whereas matching the card *is* this thing's whole job.
    ///
    /// **`min`, not `max` — a "contain" fit**, so the floor never spills past the card's edge.
    /// The asset is authored to the card's proportions, so it costs a few tenths of a millimetre
    /// on one axis, which the mask underneath covers.
    ///
    /// **The y placement is what stops models looking like they are flying.** See `seafloorEmbed`.
    func seafloor(under model: Entity, sizedTo cardSize: CGSize,
                  report: (String) -> Void) -> Entity? {
        guard let seafloorModel, !Self.contains(prefix: seafloorPrefix, in: model) else { return nil }

        let floor = seafloorModel.clone(recursive: true)
        // Bounds in the clone's *own* space, which is the space `scale` and `position` below are
        // applied in — so the two are measured and written in the same frame of reference.
        let surface = Self.find(prefix: seafloorSurfacePrefix, in: floor) ?? floor
        let bounds = surface.visualBounds(relativeTo: floor)

        guard bounds.extents.x > 0, bounds.extents.z > 0,
              cardSize.width > 0, cardSize.height > 0
        else {
            report("""
                Could not size \(seafloorModelName): card measures \(cardSize.width) × \
                \(cardSize.height) m, floor measures \(bounds.extents.x) × \(bounds.extents.z) m.
                """)
            return nil
        }

        // The anchor's axes follow the card: x across its printed width, z down its printed height,
        // y out of its surface — so `physicalSize.height` is a depth here, not a height.
        let scale = min(Float(cardSize.width) / bounds.extents.x,
                        Float(cardSize.height) / bounds.extents.z)
        floor.scale = .init(repeating: scale)

        // Centred on the card in x and z, same solve as `fit(_:named:)`. In y it is the *top* of the
        // sand that gets placed, not its bottom: the models stand with their base at y = 0, so where
        // the surface they stand on lands is the only thing that matters, and `seafloorEmbed` lifts
        // it just above that plane so they sit in the sand rather than on top of it.
        floor.position = [
            -bounds.center.x * scale,
            seafloorEmbed - (bounds.center.y + bounds.extents.y / 2) * scale,
            -bounds.center.z * scale
        ]
        return floor
    }

    /// Whether anything in `entity`'s tree is named with `prefix`. Same walk as
    /// `PinchInteraction.find(prefix:in:)`, stopping at the first hit.
    private static func contains(prefix: String, in entity: Entity) -> Bool {
        entity.name.hasPrefix(prefix) || entity.children.contains { contains(prefix: prefix, in: $0) }
    }

    /// The first entity in `entity`'s tree whose name starts with `prefix`.
    private static func find(prefix: String, in entity: Entity) -> Entity? {
        if entity.name.hasPrefix(prefix) { return entity }
        for child in entity.children {
            if let found = find(prefix: prefix, in: child) { return found }
        }
        return nil
    }

    /// Decodes the asset catalog's reference images off the main thread.
    ///
    /// This is the call that used to block the camera screen's presentation. It is still the same
    /// work — the card images have to be decoded and their features extracted — but it now happens
    /// while `LoadingView` is on screen, and only once per launch.
    private static func loadReferenceImages() async -> [ARReferenceImage] {
        // Read on the main actor and captured, rather than touched inside the detached task:
        // approachable concurrency isolates globals to the main actor, and reaching for one from
        // off it is an error under the Swift 6 language mode.
        let group = arResourceGroupName
        return await Task.detached(priority: .userInitiated) {
            let images = ARReferenceImage.referenceImages(inGroupNamed: group, bundle: nil) ?? []
            return images.sorted { ($0.name ?? "") < ($1.name ?? "") }
        }.value
    }

    /// Strips any camera the model brought with it.
    ///
    /// A `.usdz` is a scene, not a mesh, and a Blender export carries the viewport camera.
    /// RealityKit turns a USD `Camera` prim into a real `PerspectiveCamera`, and adding one to an
    /// `ARView` scene hands rendering to it — **the passthrough video freezes**, with no error and
    /// nothing in the log. Imported lights are inert and left alone; cameras are not.
    private static func removeCameras(from entity: Entity) {
        // Snapshot the children, because the recursive call can remove one of them.
        for child in Array(entity.children) {
            removeCameras(from: child)
        }
        if entity.components.has(PerspectiveCameraComponent.self) {
            entity.removeFromParent()
        }
    }

    /// Strips the sky a model brought with it.
    ///
    /// The same hazard as `removeCameras(from:)`, and the newer half of it. A Blender export
    /// carries the world as a dome light, and RealityKit — since iOS 18 — imports a USD
    /// `DomeLight` as an `ImageBasedLightComponent`. That component *overrides* the scene's own
    /// environment for the subtree it sits on, so whatever `ARView.environment.lighting` is set to
    /// stops reaching the model, silently and with nothing in the log.
    ///
    /// Every `.usdz` in this project ships one and every one of them is near-black — the dome's
    /// colour is baked to a one-pixel `.exr` named after its hex, and the bundle holds
    /// `color_0C0C0C.exr` (`Showcase_Coral`) and `color_191C21.exr` (`Showcase_Drupella` and both
    /// simulation cards). A model lit by that renders almost black whatever the room is doing,
    /// which is exactly what it looked like.
    ///
    /// The *other* imported lights are still left alone, and still inert: a Blender point or sun
    /// light comes in as an entity with no light component and changes nothing. It is only the
    /// world that survives the trip. See docs/models.md.
    private static func removeImportedLighting(from entity: Entity) {
        entity.components.remove(ImageBasedLightComponent.self)
        entity.components.remove(ImageBasedLightReceiverComponent.self)
        for child in entity.children { removeImportedLighting(from: child) }
    }

    /// Scales a model to its fixed target width (`modelWidths`) and sits it centred on its card,
    /// base on the surface.
    ///
    /// Anchoring supplies position and rotation, never scale, so without this the model renders at
    /// whatever real-world size it was authored at — a number with no relation to either the card
    /// or the on-screen size actually wanted. Measuring at load time instead means any `.usdz`
    /// lands at exactly its target width regardless of authored scale.
    ///
    /// The whole model is measured, including a planting card's loose corals — nothing is moved at
    /// load time, so the arrangement the asset was authored with is the one being sized.
    private func fit(_ model: Entity, named name: String) {
        let bounds = model.visualBounds(relativeTo: nil)
        let targetWidth = modelWidths[name] ?? defaultModelWidth

        // Worth reporting rather than skipping quietly: a model authored in metres, left unscaled
        // at a target width a few centimetres wide, puts the camera inside the mesh. The screen
        // fills with texture that barely moves, which reads as a frozen app rather than a sizing bug.
        guard targetWidth > 0, bounds.extents.x > 0 else {
            errors.append("""
                Could not size \(name): target width is \(targetWidth) m, model measures \
                \(bounds.extents.x) m. Showing it at its authored size.
                """)
            return
        }

        let scale = targetWidth / bounds.extents.x
        model.scale = .init(repeating: scale)

        // The anchor's axes follow the card: x across its width, z down its height, y out of its
        // surface. A model point `p` lands at `scale * p + position`, and the `.usdz` origin is
        // wherever the artist left it — so centre the measured box in x and z, and lift the model
        // until the bottom of the box sits at y = 0.
        model.position = [
            -bounds.center.x * scale,
            (bounds.extents.y / 2 - bounds.center.y) * scale,
            -bounds.center.z * scale
        ]
    }
}
