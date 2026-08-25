//
//  Annotations.swift
//  PostcardAR
//
//  Explanation labels pinned to points inside a card's model — as entities in the scene, not as
//  an overlay on the screen.
//
//  A model may carry any number of `ANNO*` entities. Each one's transform is a place on the model
//  worth explaining; the words come from `<card name>.json` beside the `.usdz`, matched to the
//  entity by name. Nothing here is card-specific, and nothing turns on the card's kind: a model
//  with no such entities, or a card with no JSON file, simply has no annotations.
//
//  Each annotation becomes three entities parented to the card's pivot — a dot on the point, a
//  billboarded panel out on a ring around the model, and a leader line joining them. They are
//  built **once**, at load, and then RealityKit owns them: they move, tilt, hide and lock with the
//  card like the model does, and `BillboardComponent` keeps the panels facing the camera. There is
//  no per-frame work here at all.
//
//  `PostcardARView.Coordinator` owns one `AnnotationLayer` and talks to it through a single call —
//  `collect(from:in:named:report:)`, once per loaded model. See docs/annotations.md.
//

import RealityKit
import SwiftUI
import UIKit // `UIColor`, and the tap's haptic

// MARK: - Tuning

/// Prefix marking an entity whose transform positions an explanation label. Same idiom as the
/// `Drupella` prefix in `PinchInteraction`: the model declares its own content by naming, and no
/// individual card is named in the source.
///
/// Matched case-sensitively, like every other prefix here, and the case is the assets' —
/// `Showcase_Coral.usdz` names its markers `ANNO_Tentacle`, `ANNO_Mouth` and so on. A marker
/// called `Annotation_x` does **not** match.
private let annotationPrefix = "ANNO"

/// Width, in points, that `AnnotationBox` is laid out at before being rendered to a texture. The
/// height follows from however far the body text wraps, and the panel's aspect ratio follows from
/// that — nothing here assumes a number of lines.
private let annotationBoxMaxWidth: CGFloat = 150

/// Supersampling for the panel texture. The label is a texture in the world now rather than
/// screen-space text, so it gets magnified whenever the phone comes close; rendering at 3× is what
/// keeps it from going soft when someone leans in.
private let annotationRenderScale: CGFloat = 3

/// How many metres one laid-out point is worth — the dial that turns the rendered label into a
/// panel size. At 150 pt wide this gives a panel about 10.5 cm across, against a model sized to
/// 0.3 m by `modelWidths`. **Raise it to make every label bigger.**
private let annotationMetresPerPoint: Float = 0.0007

/// How far beyond the model's own silhouette the ring of panels sits, in metres.
private let annotationRingMargin: Float = 0.05

/// Thickness of a leader line, in metres.
private let annotationLeaderThickness: Float = 0.0018

/// Radius of the dot left on the marker point itself, in metres. It is the tap target as well as
/// the marker, so it is drawn a little larger than a pure marker would need to be.
private let annotationDotRadius: Float = 0.003

private let annotationLineColor = UIColor(named: "SecondaryBlue")!

/// The material both markers wear — see `annotationLineColor`.
///
/// **`applyPostProcessToneMap: false` is what makes white actually white.** An ordinary
/// `UnlitMaterial` still goes through the renderer's filmic tone map on its way to the screen, and
/// that curve rolls the top of its range off: a marker authored at pure `#FFFFFF` lands somewhere
/// around light grey, which against a bright reef is close to invisible. These two are interface,
/// not scenery — they mark a spot and say "press here" — so they are the one thing in the scene
/// that should be exempt from the grade the models are being given.
private func annotationMarkerMaterial() -> UnlitMaterial {
    var material = UnlitMaterial(applyPostProcessToneMap: false)
    material.color = .init(tint: annotationLineColor)
    return material
}

/// How close a tap has to land to a dot's projected position, in screen points, to toggle it.
///
/// Screen points and a nearest-match search, **not** a RealityKit hit test — the same choice, for
/// the same reasons, as `PinchInteraction.attemptGrab(at:)`. A hit test needs a `CollisionComponent`
/// on every dot, and a dot is 6 mm across: its true silhouette is a few points wide at arm's length,
/// which is not something anyone can hit. Matching by proximity makes the target as forgiving as
/// this number says, independent of how big the dot is drawn.
private let annotationTapRadius: CGFloat = 44

// MARK: - The JSON file

/// One entry in a card's `<name>.json`, which is a plain array of these:
///
/// ```json
/// [
///   { "entity": "ANNO_Mouth", "title": "Mouth", "body": "The polyp's only opening." }
/// ]
/// ```
///
/// An array rather than a dictionary keyed by entity name, so the file's own order is the order
/// labels are numbered in, and editing it is editing a list rather than a tree.
private struct AnnotationText: Decodable {
    /// Name of the `ANNO*` entity in the `.usdz` this text belongs to.
    let entity: String
    let title: String

    /// Spelled `body` in the file because that reads naturally to whoever edits it; renamed here
    /// only because `body` means something else in a `View`.
    let detail: String

    private enum CodingKeys: String, CodingKey {
        case entity, title
        case detail = "body"
    }
}

// MARK: - AnnotationLayer

/// Builds each card's annotations into its scene.
///
/// **In the scene, not on the screen.** An earlier version projected every marker to a screen point
/// each frame and drew SwiftUI boxes over the camera; this builds RealityKit entities once and lets
/// the engine do the rest. The labels are then genuinely part of the world — they tilt with the
/// card, are occluded by the model and by hands, and shrink with distance.
///
/// RealityKit on iOS cannot host a SwiftUI view in a scene — `ViewAttachmentComponent` is
/// visionOS-only — so a panel is a quad wearing a texture rendered from `AnnotationBox` by
/// `ImageRenderer`. See docs/annotations.md.
@MainActor
final class AnnotationLayer {
    /// One built annotation: the dot that is tapped, and the two entities that appear when it is.
    ///
    /// The dot is always drawn; the panel and its leader line start hidden and are switched on by
    /// `toggle(at:in:)`. Kept in a flat array across every loaded card, like `PinchInteraction`'s
    /// grabbable pool, because a tap is answered by whichever dot is nearest on screen regardless
    /// of which card's model it came from.
    private struct Marker {
        /// Drawn always, and the thing the tap search matches against.
        let dot: Entity

        /// Hidden until this marker is switched on.
        let panel: Entity
        let leader: Entity?
    }

    private var markers: [Marker] = []

    /// Fires when a tap actually lands on a dot, so the tap is felt as well as seen. A tap that hits
    /// nothing stays silent, which is what tells the two apart without anything on screen saying so.
    private let tapHaptics = UIImpactFeedbackGenerator(style: .light)

    /// Shows or hides the panel for whichever dot the tap landed nearest, and reports whether it
    /// found one.
    ///
    /// Every panel starts hidden: nine of them open at once is the unreadable clump this design
    /// exists to avoid, and a reader wants one part explained at a time. Tapping is a *toggle* per
    /// dot rather than a single-selection, so several can be left open deliberately while a stray
    /// tap on open air changes nothing.
    ///
    /// Dots on a card that is not on screen are skipped via `isEnabledInHierarchy` — the same guard
    /// `attemptGrab(at:)` uses on hidden cards' snails — so a tap can never open a label belonging
    /// to a card nobody is pointing at.
    @discardableResult
    func toggle(at point: CGPoint, in arView: ARView) -> Bool {
        let nearest = markers.indices
            .compactMap { index -> (Int, CGFloat)? in
                guard markers[index].dot.isEnabledInHierarchy,
                      let projected = arView.project(markers[index].dot.position(relativeTo: nil))
                else { return nil }
                return (index, hypot(projected.x - point.x, projected.y - point.y))
            }
            .filter { $0.1 < annotationTapRadius }
            .min { $0.1 < $1.1 }

        guard let (index, _) = nearest else { return false }

        let showing = !markers[index].panel.isEnabled
        markers[index].panel.isEnabled = showing
        markers[index].leader?.isEnabled = showing
        tapHaptics.impactOccurred()
        return true
    }

    /// Warms the Taptic Engine, so the first tap of a session is not the slow one. Called when the
    /// coordinator wires up its tap recogniser.
    func prepareHaptics() {
        tapHaptics.prepare()
    }

    /// Pairs a loaded model's `ANNO*` entities with the text in `<name>.json`, and builds the
    /// dot, panel and leader line for each into `container`.
    ///
    /// - Parameters:
    ///   - model: the card's loaded `.usdz`, already scaled by `fit(_:named:)`.
    ///   - container: what the annotation entities are parented to — the card's *pivot*, not the
    ///     model. The model carries `fit`'s scale factor, which is whatever it took to bring that
    ///     particular `.usdz` to its target width; building inside it would make every size here a
    ///     function of the asset's authored units. The pivot is plain metres.
    ///
    /// Both halves are reported when they disagree, because that is the mistake this design invites:
    /// the entity name in Blender and the entity name in the JSON file have to match exactly, and
    /// nothing but a message on screen will tell you they do not.
    /// - Returns: whether this card actually got any labels built — `false` for the ordinary case
    ///   of a card with no `ANNO*`/no JSON, distinct from the mistake cases which still return
    ///   `false` but go through `report`. Lets the coordinator know, without re-deriving it, which
    ///   cards are worth telling the player to tap — see `ARStatus.annotatedShowcaseVisible`.
    @discardableResult
    func collect(from model: Entity, in container: Entity, named name: String,
                 report: (String) -> Void) -> Bool {
        let entities = find(prefix: annotationPrefix, in: model)
        let texts = loadTexts(named: name, report: report)

        // No JSON and no entities is the ordinary case for most cards — silent. One without the
        // other is a mistake worth naming.
        if texts.isEmpty {
            if !entities.isEmpty {
                report("""
                    \(name).usdz has \(entities.count) \(annotationPrefix) entities but no \
                    \(name).json to label them with.
                    """)
            }
            return false
        }

        var byName = Dictionary(entities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var matched: [(entity: Entity, title: String, detail: String)] = []
        for text in texts {
            guard let entity = byName.removeValue(forKey: text.entity) else {
                report("\(name).json names \"\(text.entity)\", which is not in \(name).usdz.")
                continue
            }
            // Strip any geometry the marker brought — a point authored as a visible cube rather
            // than an empty would otherwise render as a stray blob on the model. The transform is
            // all that is wanted, and it is left alone.
            hideGeometry(of: entity)
            matched.append((entity, text.title, text.detail))
        }

        for leftover in byName.keys.sorted() {
            report("\(name).usdz has \"\(leftover)\" with no entry in \(name).json.")
        }

        build(matched, from: model, in: container, named: name, report: report)
        return !matched.isEmpty
    }

    /// Lays the panels out on a ring around the model and builds the entities.
    ///
    /// **Panels are not built at their markers.** On an anatomy model the markers are wherever the
    /// anatomy is, and the anatomy is small: `Showcase_Coral.usdz` puts six of its nine within a
    /// couple of millimetres of each other, so panels built in place would interpenetrate into one
    /// unreadable clump. Each is pushed out to a ring instead, with a leader line back to its point.
    ///
    /// The ring is around the model's **vertical axis**, and that is the part worth keeping. Pushing
    /// panels apart only within the card's plane looks right from one side and collapses from the
    /// other; spreading them by angle means that from wherever the phone happens to be, some panels
    /// are in front of the model and some behind, and walking around reveals the rest. Angles are
    /// assigned by marker height so the ring spirals up the model rather than crowding one band, and
    /// each panel keeps its own marker's height so its leader line stays roughly horizontal.
    private func build(_ items: [(entity: Entity, title: String, detail: String)],
                       from model: Entity, in container: Entity, named name: String,
                       report: (String) -> Void) {
        guard !items.isEmpty else { return }

        let bounds = model.visualBounds(relativeTo: container)
        let radius = max(bounds.extents.x, bounds.extents.z) / 2 + annotationRingMargin

        // Sorted by height, with the name breaking ties, so the ring is stable and reproducible
        // rather than following whatever order the JSON happened to be written in.
        let ordered = items
            .map { (item: $0, position: $0.entity.position(relativeTo: container)) }
            .sorted { ($0.position.y, $0.item.entity.name) < ($1.position.y, $1.item.entity.name) }

        let step = 2 * Float.pi / Float(ordered.count)

        for (index, entry) in ordered.enumerated() {
            guard let panel = Self.panel(title: entry.item.title, detail: entry.item.detail) else {
                report("Could not render the label for \(entry.item.entity.name) on \(name).")
                continue
            }

            let angle = step * Float(index)
            let target = SIMD3<Float>(bounds.center.x + radius * cos(angle),
                                      entry.position.y,
                                      bounds.center.z + radius * sin(angle))

            panel.entity.position = target
            // Always face the camera. Without this a panel is readable from one angle and edge-on
            // from every other, which is the whole reason a flat label in a 3D scene usually fails.
            panel.entity.components.set(BillboardComponent())
            // Off until its dot is tapped. Note this is the entity's *own* `isEnabled`, which is
            // independent of the pivot's — the card going out of view hides the whole branch
            // without disturbing which panels the reader has opened, and they come back as they
            // were when it returns.
            panel.entity.isEnabled = false
            container.addChild(panel.entity)

            let dot = Self.dot(at: entry.position)
            container.addChild(dot)

            let leader = Self.leader(from: entry.position, to: target, clearing: panel.width / 2)
            if let leader {
                leader.isEnabled = false
                container.addChild(leader)
            }

            markers.append(Marker(dot: dot, panel: panel.entity, leader: leader))
        }
    }

    // MARK: Building the pieces

    /// A quad wearing a texture of `AnnotationBox`, and how wide it ended up in metres.
    ///
    /// The height is not chosen: `ImageRenderer` lays the view out at `annotationBoxMaxWidth` and
    /// reports whatever pixel size the text wrapped to, and the quad takes that aspect ratio. So a
    /// two-line body and a four-line body both come out correctly proportioned with no constant to
    /// keep in step — which is exactly what a fixed row height could not do.
    private static func panel(title: String, detail: String) -> (entity: ModelEntity, width: Float)? {
        let renderer = ImageRenderer(content: AnnotationBox(title: title, detail: detail))
        renderer.scale = annotationRenderScale
        renderer.isOpaque = false // the box has rounded corners; the rest must stay transparent

        guard let image = renderer.cgImage,
              let texture = try? TextureResource(
                  image: image, withName: nil,
                  options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        else { return nil }

        let width = Float(image.width) / Float(annotationRenderScale) * annotationMetresPerPoint
        let height = Float(image.height) / Float(annotationRenderScale) * annotationMetresPerPoint

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        // The texture carries alpha for the rounded corners, so it has to blend rather than being
        // cut out — `opacityThreshold` would give the corners a hard, aliased edge.
        material.blending = .transparent(opacity: 1.0)
        // Unlit on purpose, unlike the card mask: this is text to be read, not a surface. A lit
        // panel would dim in a dim room, which is precisely when the label needs to stay legible.

        let entity = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
        return (entity, width)
    }

    /// The dot left on the marker point itself.
    private static func dot(at position: SIMD3<Float>) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateSphere(radius: annotationDotRadius),
                                 materials: [annotationMarkerMaterial()])
        entity.position = position
        return entity
    }

    /// The line joining a marker to its panel: a thin box, stretched along the gap and rotated onto
    /// it.
    ///
    /// `clearance` stops the line short of the panel's centre so it does not spear through the
    /// billboard and out the other side. Half the panel's *width* is used — its largest silhouette
    /// radius — so the line stops clear whichever way the billboard happens to be turned.
    private static func leader(from start: SIMD3<Float>, to end: SIMD3<Float>,
                               clearing clearance: Float) -> ModelEntity? {
        let span = end - start
        let distance = simd_length(span)
        let length = distance - clearance
        guard length > 0.001 else { return nil } // panel sits on top of its own marker

        let entity = ModelEntity(
            mesh: .generateBox(width: annotationLeaderThickness,
                               height: annotationLeaderThickness,
                               depth: length),
            materials: [annotationMarkerMaterial()])

        let direction = span / distance
        // `generateBox` builds along +z, so rotate +z onto the direction of travel and sit the box
        // at the midpoint of the part of the gap it actually covers.
        entity.orientation = simd_quatf(from: [0, 0, 1], to: direction)
        entity.position = start + direction * (length / 2)
        return entity
    }

    // MARK: Reading the model and the file

    private func find(prefix: String, in entity: Entity) -> [Entity] {
        var found = entity.name.hasPrefix(prefix) ? [entity] : []
        for child in entity.children {
            found.append(contentsOf: find(prefix: prefix, in: child))
        }
        return found
    }

    /// Removes the mesh from an entity and everything under it, leaving the transform alone.
    ///
    /// `isEnabled = false` would be simpler and is wrong here: if a marker were ever authored as the
    /// *parent* of real geometry it would take that with it.
    private func hideGeometry(of entity: Entity) {
        entity.components.remove(ModelComponent.self)
        for child in entity.children {
            hideGeometry(of: child)
        }
    }

    /// Reads `<name>.json` from the bundle. A missing file is not an error — most cards have none.
    private func loadTexts(named name: String, report: (String) -> Void) -> [AnnotationText] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json") else { return [] }
        do {
            return try JSONDecoder().decode([AnnotationText].self, from: Data(contentsOf: url))
        } catch {
            report("Could not read \(name).json: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - The label

/// One annotation's card of text. Never added to the view hierarchy — it exists to be laid out and
/// rendered to a texture by `AnnotationLayer.panel(title:detail:)`, which is why it fixes its own
/// width and lets its height follow the text.
///
/// The border is the whole point — over a camera feed of a reef, an unbordered panel has nothing
/// separating it from the picture behind.
struct AnnotationBox: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: annotationBoxMaxWidth, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.78), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
        }
        .foregroundStyle(.white)
    }
}

#Preview {
    AnnotationBox(title: "Tentacles",
                  detail: "A ring of stinging arms around the mouth. They fire tiny harpoons to catch plankton.")
        .padding()
        .background(.blue)
}
