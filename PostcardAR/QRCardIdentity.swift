//
//  QRCardIdentity.swift
//  PostcardAR
//
//  Reads a card's name off a QR printed on it, so *which model to draw* stops depending on ARKit
//  telling two similar reference images apart:
//
//      reference image  ->  where the card is        (ARKit, pose only)
//      QR payload       ->  which model goes on it   (Vision, identity only)
//
//  Two cards that look alike to a feature matcher are then harmless: whichever image ARKit decides
//  it matched, the anchor still lands on the card in front of the lens, and the payload names the
//  model independently. Reference images only have to track *well*, not *distinguishably*.
//
//  The payload is the card name verbatim — `Simulation_Coral`, not an id needing a table — so it
//  feeds the same `name -> name.usdz` pairing the bundle already drives, and adding a card stays
//  "drop the files, change no code". `PostcardARView.Coordinator.rebind(to:)` acts on it.
//
//  Known limits, both from there being one payload and one binding:
//
//    * Two cards in frame at once bind to whichever reference image ARKit lists first, so the
//      model can land on the wrong one. Fixing that means matching each payload's corner points
//      against each anchor's projected position — `BarcodeObservation` carries the corners.
//    * Swapping card A for card B draws A's model on B until B's QR reads, bounded by
//      `payloadHoldSamples`.
//

import Vision

/// How many samples a decoded name survives after the last one that read it — 45 at the sampler's
/// 15 Hz is three seconds. Long enough that a blurred frame or a passing hand does not drop the
/// name; the cost is that swapping one card for another shows the outgoing model for that long.
///
/// The *binding* in `PostcardARView` outlives this hold entirely — a hand over the card stops the
/// decode long before it stops the game.
private let payloadHoldSamples = 45

/// One card name read off the camera.
///
/// No confidence threshold, on purpose: a QR carries its own error correction, so a payload that
/// decodes at all has already passed a checksum. Unlike the feature match this replaces, a *wrong*
/// answer is close to impossible and the only failure mode is *no* answer.
struct QRCardIdentity {
    /// Reused across samples, and QR only: the request scans for every symbology it is handed, and
    /// the other thirty-odd are pure cost per frame here.
    static let request: DetectBarcodesRequest = {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }()

    /// The last name decoded, held for `payloadHoldSamples` and cleared after, so a stale name
    /// cannot sit on screen once the card has gone.
    private(set) var payload: String?

    private var missesSinceDecode = 0

    /// Records one sample's worth of observations, decoded or empty.
    mutating func note(_ observations: [BarcodeObservation]) {
        // First rather than best: one card in frame is the case this handles. Two QRs in view
        // needs the corner points to say which anchor each belongs to.
        guard let decoded = observations.first(where: { $0.payloadString != nil })?.payloadString
        else {
            missesSinceDecode += 1
            if missesSinceDecode >= payloadHoldSamples { payload = nil }
            return
        }
        payload = decoded
        missesSinceDecode = 0
    }

    /// Records a decode from a one-off high-resolution capture. Misses are not fed here: a scan
    /// that found nothing says only that the card was not pointed at a code yet.
    mutating func noteHighResolution(_ observations: [BarcodeObservation]) {
        guard let decoded = observations.first(where: { $0.payloadString != nil })?.payloadString
        else { return }
        payload = decoded
        missesSinceDecode = 0
    }
}
