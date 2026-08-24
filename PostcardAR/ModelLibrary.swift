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
    "Showcase_Coral": 0.13,
    "Showcase_Drupella": 0.08,
    "Simulation_Coral": 0.4,
    "Simulation_Drupella": 0.55,
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

    /// Collected rather than replaced, same as `ARStatus.errors`: with several models, one missing
    /// `.usdz` must not hide the next. Handed to `ARStatus` when a coordinator starts, since the
    /// status panel does not exist yet at load time.
    private(set) var errors: [String] = []

    /// Sorted by name, so the status list does not reshuffle between runs.
    @ObservationIgnored private(set) var referenceImages: [ARReferenceImage] = []

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
        total = referenceImages.count

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
                seafloorModel = floor
            } catch {
                errors.append("Could not load \(seafloorModelName).usdz: \(error.localizedDescription)")
            }
        }

        // One at a time rather than all at once: decoding and texture upload happen on the main
        // thread either way, so overlapping them would only make a longer stall.
        for image in referenceImages {
            // An unnamed entry cannot be anchored to or matched to a `.usdz`. Xcode names them
            // from the filename, so this is close to unreachable.
            guard let name = image.name else { continue }
            do {
                let model = try await Entity(named: name)
                Self.removeCameras(from: model)
                fit(model, named: name)
                models[name] = model
            } catch {
                errors.append("Could not load \(name).usdz: \(error.localizedDescription)")
            }
            loaded += 1
        }

        isReady = true
    }

    /// A fresh copy of one card's model, or `nil` if it failed to load.
    ///
    /// **A clone, not the model itself.** A scan mutates what it is given — corals are carried to
    /// plant points, snails are hidden and faded, `hideGeometry(of:)` strips annotation markers —
    /// and `PinchInteraction` reads each piece's *current* transform as the `home` it restores to.
    /// Handing back the same tree on the next scan would therefore record a planted coral's slot
    /// as its home, and a half-played model would be on screen before the run even began.
    ///
    /// Cloning costs nothing worth measuring next to loading: `MeshResource` and the materials are
    /// reference-backed handles, so a clone shares the GPU resources rather than uploading them
    /// again. What it copies is the entity tree and its components.
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
    /// **`min`, not `max` — a "contain" fit.** The floor is never allowed to spill past the card.
    /// That costs nothing here because the asset is authored to the card's proportions: the sand
    /// measures 9.747 × 12.682 (0.7686) against a 5855 × 7605 card (0.7699), so a uniform scale
    /// lands within about 0.2% on both axes and the "gap" is a few tenths of a millimetre — which
    /// the card mask underneath covers anyway. Should a future card have a different aspect ratio,
    /// `min` keeps the floor inside its edges rather than hanging over the table.
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
    /// A `.usdz` is a scene, not a mesh: exported from Blender it carries the lighting rig and the
    /// viewport camera too. RealityKit turns a USD `Camera` prim into a real `PerspectiveCamera`
    /// entity, and adding one to an `ARView` scene hands rendering over to it — the passthrough
    /// video freezes, with no error and nothing in the log. Imported lights are inert and are left
    /// alone; cameras are not.
    ///
    /// Done once here rather than per scan, so the clones never carry one.
    private static func removeCameras(from entity: Entity) {
        // Snapshot the children, because the recursive call can remove one of them.
        for child in Array(entity.children) {
            removeCameras(from: child)
        }
        if entity.components.has(PerspectiveCameraComponent.self) {
            entity.removeFromParent()
        }
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
