//
//  Annotations.swift
//  PostcardAR
//
//  Explanation labels pinned to points inside a card's model.
//
//  A model may carry any number of `Annotation*` entities. Each one's transform is a place on the
//  model worth explaining; the words come from `<card name>.json` beside the `.usdz`, matched to
//  the entity by name. Nothing here is card-specific, and nothing turns on the card's kind: a model
//  with no such entities, or a card with no JSON file, simply has no annotations.
//
//  `PostcardARView.Coordinator` owns one `AnnotationLayer` and talks to it through two calls —
//  `collect(from:named:report:)` once per loaded model, and `update(in:)` once a rendered frame.
//  `ContentView` reads `placed` and draws it. See docs/annotations.md.
//

import RealityKit
import SwiftUI

// MARK: - Tuning

/// Prefix marking an entity whose transform positions an explanation label. Same idiom as the
/// `Drupella` prefix in `PinchInteraction`: the model declares its own content by naming, and no
/// individual card is named in the source.
private let annotationPrefix = "Annotation"

/// How far above its anchor point, in screen points, a label's bottom edge sits — enough to clear
/// the dot and the thing being described rather than covering it.
private let annotationBoxOffset: CGFloat = 54

/// Widest a label gets before its text wraps.
private let annotationBoxMaxWidth: CGFloat = 190

// MARK: - The JSON file

/// One entry in a card's `<name>.json`, which is a plain array of these:
///
/// ```json
/// [
///   { "entity": "Annotation_polyp", "title": "Polyps", "body": "Each cup is one animal." }
/// ]
/// ```
///
/// An array rather than a dictionary keyed by entity name, so the file's own order is the order
/// labels are numbered in, and editing it is editing a list rather than a tree.
private struct AnnotationText: Decodable {
    /// Name of the `Annotation*` entity in the `.usdz` this text belongs to.
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

/// The annotations across every loaded model, and where they land on screen this frame.
///
/// Screen space, not 3D. RealityKit on iOS has no way to host a SwiftUI view in the scene —
/// `ViewAttachmentComponent` is visionOS-only — and the alternative, `MeshResource.generateText`,
/// builds an extruded mesh per string that needs rebuilding on every edit, billboarding to face the
/// camera, and manual distance-scaling to stay legible at a few centimetres wide. Projecting the
/// anchor point and drawing an ordinary SwiftUI box costs one `project(_:)` per label per frame —
/// the same call `PinchInteraction.attemptGrab(at:)` already makes for every grabbable entity.
@Observable
final class AnnotationLayer {
    /// One annotation, placed for this frame. `Equatable` so the per-frame write can be guarded:
    /// `@Observable` notifies on every set without comparing, and a still card projects to the same
    /// points frame after frame — the pose dead band in `PostcardARView` is what makes that true.
    struct Placed: Equatable, Identifiable {
        /// The entity's name, unique within a model and stable across frames.
        let id: String
        let title: String
        let detail: String

        /// Where the entity's origin lands in the view, in points.
        let point: CGPoint
    }

    private(set) var placed: [Placed] = []

    /// One annotation waiting to be placed: the entity that positions it, and its text.
    private struct Annotation {
        let entity: Entity
        let title: String
        let detail: String
    }

    /// Every annotation across every loaded model, flattened. Not observed — it changes only at
    /// load time, and `placed` is what anything draws from.
    @ObservationIgnored private var annotations: [Annotation] = []

    /// Pairs a loaded model's `Annotation*` entities with the text in `<name>.json`.
    ///
    /// Both halves are reported when they disagree, because that is the mistake this design invites:
    /// the entity name in Blender and the entity name in the JSON file have to match exactly, and
    /// nothing but a message on screen will tell you they do not.
    func collect(from model: Entity, named name: String, report: (String) -> Void) {
        let entities = findAnnotations(in: model)
        let texts = loadTexts(named: name, report: report)

        // No JSON and no entities is the ordinary case for most cards — silent. One without the
        // other is a mistake worth naming.
        if texts.isEmpty {
            if !entities.isEmpty {
                report("""
                    \(name).usdz has \(entities.count) Annotation entities but no \(name).json \
                    to label them with.
                    """)
            }
            return
        }

        var byName = Dictionary(entities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for text in texts {
            guard let entity = byName.removeValue(forKey: text.entity) else {
                report("\(name).json names \"\(text.entity)\", which is not in \(name).usdz.")
                continue
            }
            // Keep the entity enabled — `update(in:)` reads `isEnabledInHierarchy` to know whether
            // its card is on screen — but strip any geometry it brought, so a marker authored as a
            // visible cube rather than an empty does not render as a stray blob on the model.
            hideGeometry(of: entity)
            annotations.append(Annotation(entity: entity, title: text.title, detail: text.detail))
        }

        for leftover in byName.keys.sorted() {
            report("\(name).usdz has \"\(leftover)\" with no entry in \(name).json.")
        }
    }

    /// Projects every annotation to a screen point. Called once per rendered frame.
    ///
    /// Skips any whose card is off screen (`isEnabledInHierarchy` — a showcase card's model is
    /// disabled the moment its card is lost) and any behind the camera, which `project(_:)` reports
    /// by returning `nil`.
    func update(in arView: ARView) {
        var next: [Placed] = []
        for annotation in annotations {
            guard annotation.entity.isEnabledInHierarchy,
                  let point = arView.project(annotation.entity.position(relativeTo: nil))
            else { continue }
            next.append(Placed(id: annotation.entity.name,
                               title: annotation.title,
                               detail: annotation.detail,
                               point: point))
        }
        if placed != next { placed = next }
    }

    private func findAnnotations(in entity: Entity) -> [Entity] {
        var found = entity.name.hasPrefix(annotationPrefix) ? [entity] : []
        for child in entity.children {
            found.append(contentsOf: findAnnotations(in: child))
        }
        return found
    }

    /// Removes the mesh from an entity and everything under it, leaving the transform alone.
    ///
    /// `isEnabled = false` would be simpler and is wrong here twice over: it would also switch off
    /// the transform's visibility test in `update(in:)`, and if a marker were ever authored as the
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

/// One annotation: a bordered card of text, and a dot marking the spot it describes.
///
/// The border is the whole point — over a camera feed of a reef, an unbordered panel has nothing
/// separating it from the picture behind.
///
/// The card and the dot are two independently positioned views rather than one stacked view with a
/// stem between them. SwiftUI's `.position(_:)` places a view's *centre*, so anchoring the bottom of
/// a stack on the point would need the stack's height — and that height depends on how long the body
/// text wraps to. A dot on the point and a card a fixed distance above it needs no measurement, and
/// the offset stays a number anyone can tune.
struct AnnotationBox: View {
    let title: String
    let detail: String

    /// How far above the projected point the card's centre sits.
    static let offset = annotationBoxOffset

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: annotationBoxMaxWidth, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.72), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }
}

/// The dot that sits on the annotated point itself.
struct AnnotationDot: View {
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 9, height: 9)
            .overlay { Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 2)
    }
}
