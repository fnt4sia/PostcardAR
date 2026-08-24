//
//  QRCardIdentity.swift
//  PostcardAR
//
//  Reads a card's name off a QR printed on it, so that *which model to draw* stops depending on
//  ARKit telling two similar reference images apart.
//
//  The split this exists to make possible:
//
//      reference image  ->  where the card is        (ARKit, pose only)
//      QR payload       ->  which model goes on it   (Vision, identity only)
//
//  Under that split two cards that look alike to a feature matcher stop being a problem: whichever
//  reference image ARKit decides it matched, the anchor still lands on the card in front of the
//  lens, and the payload names the model independently. Reference images then only have to track
//  *well*, not track *distinguishably* — which is the hard half to author.
//
//  **The payload is the card name verbatim** — `Simulation_Coral`, not an id needing a table. It
//  feeds the same `name -> name.usdz` pairing the asset catalog already drives, so adding a card
//  stays "drop two files, change no code" rather than growing a registry to keep in step.
//
//  `PostcardARView.Coordinator.rebind(to:)` acts on the payload; `decodeRate` is reported to the
//  status panel and acted on by nothing, because it is the number that says whether this whole
//  arrangement is viable — a name that arrives 30% of the time cannot carry card identity however
//  correct it is while it is there.
//
//  Known limits, both from there being one payload and one binding:
//
//    * Two cards in frame at once bind to whichever reference image ARKit lists first, so the
//      model can land on the wrong one. Fixing that means matching each payload's corner points
//      against each anchor's projected position — `BarcodeObservation` carries the corners.
//    * Swapping card A for card B draws A's model on B until B's QR reads, bounded by
//      `payloadHoldSamples`.
//

import CoreGraphics
import Vision

/// How many recent samples `decodeRate` averages over. Thirty at the sampler's 15 Hz is two
/// seconds — long enough to ride out a blurred frame or two, short enough that carrying the card
/// out to arm's length shows up in the number while you are still holding it there.
private let decodeRateWindow = 30

/// How many samples a decoded name is held for after the last sample that read it. Fifteen is a
/// second at 15 Hz — long enough that a blurred frame or a passing hand does not drop the name,
/// short enough that swapping one card for another shows the outgoing model on the incoming card
/// only briefly.
///
/// Shorter than `decodeRateWindow` on purpose, and the two must not be merged: the window is a
/// statistic being reported, this is a piece of state the app acts on. Note that the *binding*
/// in `PostcardARView` outlives this hold entirely — a hand over the card stops the decode long
/// before it stops the game.
private let payloadHoldSamples = 45

/// One card name read off the camera, and how reliably it is coming through.
///
/// There is no confidence threshold here on purpose. A QR carries its own error correction, so a
/// payload that decodes at all has already passed a checksum: unlike the feature match this is
/// meant to replace, a *wrong* answer is close to impossible and the only failure mode is *no*
/// answer. That is what makes the rate below the whole measurement — the question is never
/// "is this name right", only "how often does a name arrive".
struct QRCardIdentity {
    /// Reused across samples rather than rebuilt each time, and QR only: the request scans for
    /// every symbology it is handed, and the other thirty-odd are pure cost per frame here.
    static let request: DetectBarcodesRequest = {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }()

    /// The last name decoded, held for `payloadHoldSamples` after the sample that read it — a
    /// card does not stop being the card because one frame was blurred — and cleared after that,
    /// so a stale name cannot sit on screen once the card has gone.
    private(set) var payload: String?

    /// Fraction of the last `decodeRateWindow` samples that decoded anything, 0...1.
    ///
    /// The number the experiment turns on. Sustained high means identity can be moved off the
    /// reference images; intermittent means a QR is being asked to decode at a distance, size or
    /// motion blur it cannot, and no amount of wiring downstream will fix that.
    private(set) var decodeRate: Double = 0

    /// **Diagnostic, temporary.** The longest edge of the last code that decoded, in pixels of
    /// the captured frame, and the width of that frame.
    ///
    /// Here to answer the one question the decode rate cannot: *how big does the code have to be*.
    /// Vision wants roughly four to five pixels per module and these codes are 25–29 modules, so
    /// the number to beat is around 145 px. Only measurable on a sample that decoded — walk the
    /// card away until the rate collapses and the last reading is the practical floor.
    private(set) var pixelWidth: CGFloat?
    private(set) var imageWidth: CGFloat?

    private var window: [Bool] = []
    private var missesSinceDecode = 0

    /// Records one sample's worth of observations, decoded or empty. `imageSize` is the upright
    /// frame the corner points are normalised against — needed only by the diagnostic above.
    mutating func note(_ observations: [BarcodeObservation], in imageSize: CGSize) {
        imageWidth = imageSize.width
        // First rather than best: `maximumHandCount`'s equivalent does not exist on this request,
        // and one card in frame is the case being measured. Two QRs in view is a step-two problem
        // — it needs the corner points to say which anchor each belongs to.
        let observation = observations.first { $0.payloadString != nil }
        let decoded = observation?.payloadString
        if let decoded {
            payload = decoded
            missesSinceDecode = 0
        } else {
            missesSinceDecode += 1
            if missesSinceDecode >= payloadHoldSamples { payload = nil }
        }

        window.append(decoded != nil)
        if window.count > decodeRateWindow {
            window.removeFirst(window.count - decodeRateWindow)
        }
        decodeRate = window.isEmpty ? 0 : Double(window.count(where: { $0 })) / Double(window.count)

        // Diagnostic. Measured off the corner points rather than the bounding box, so a code held
        // at an angle reports its own edge instead of the axis-aligned box around it. Held after
        // the last decode for the same reason `payload` is — the reading matters most at the
        // distance where decoding has just started to fail.
        if let observation { measure(observation, in: imageSize) }
    }

    /// Records a decode from a one-off high-resolution capture.
    ///
    /// **Deliberately does not touch `decodeRate`.** That window is a statistic about the *video
    /// stream* — it answers "is a QR at this size readable during normal running", which is the
    /// question the printed card's design turns on. Folding an occasional photo-pipeline frame
    /// into it would report a code as fine at a size the video stream can never read.
    ///
    /// Misses are not fed here at all: a high-resolution scan that found nothing says only that
    /// the card was not pointed at a code yet, and the video stream is already counting that.
    mutating func noteHighResolution(_ observations: [BarcodeObservation], in imageSize: CGSize) {
        guard let observation = observations.first(where: { $0.payloadString != nil }),
              let decoded = observation.payloadString
        else { return }
        payload = decoded
        missesSinceDecode = 0
        imageWidth = imageSize.width
        measure(observation, in: imageSize)
    }

    /// The code's longest edge in pixels, from its corner points rather than its bounding box —
    /// so a code held at an angle reports its own edge, not the axis-aligned box around it.
    private mutating func measure(_ observation: BarcodeObservation, in imageSize: CGSize) {
        let topLeft = observation.topLeft.toImageCoordinates(imageSize, origin: .upperLeft)
        let topRight = observation.topRight.toImageCoordinates(imageSize, origin: .upperLeft)
        let bottomLeft = observation.bottomLeft.toImageCoordinates(imageSize, origin: .upperLeft)
        pixelWidth = max(hypot(topRight.x - topLeft.x, topRight.y - topLeft.y),
                         hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y))
    }
}
