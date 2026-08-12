import Foundation

/// Pure-data layout engine for the Orbit ring.
///
/// The ring is always evenly divided: `n` items means `n` slots, slot `i` at
/// `i * 360/n` degrees. Slot 0 is always twelve o'clock, so a preference of 0
/// always resolves to the top no matter how many apps are running.
///
/// Pinned apps and the dictation tile carry a *preferred direction*, not a
/// position. Each claims the free slot nearest its preference; everything
/// else fills what is left. This is what keeps the ring evenly spaced no
/// matter how many apps macOS reports as running, which fixed-angle anchors
/// could not do - clustered pins used to cram together and smear every
/// auto-added app across the remaining arc.
///
/// Angles are degrees with 0 at twelve o'clock, increasing clockwise. Output
/// is sorted clockwise from twelve, so the returned indices drive
/// scroll-to-rotate, arrow-key navigation and selection math unchanged.
enum RingLayout {
    struct Positioned: Equatable {
        let item: OrbitItem
        let angleDegrees: Double
        let isAnchored: Bool
    }

    /// Resolve `preferred` items onto the evenly spaced slot nearest each one's
    /// preferred direction, and fill every remaining slot with `others` in the
    /// order given.
    static func compute(
        preferred: [(item: OrbitItem, preferredAngle: Double)],
        others: [OrbitItem]
    ) -> [Positioned] {
        let n = preferred.count + others.count
        guard n > 0 else { return [] }

        let step = 360.0 / Double(n)
        var slots: [Positioned?] = Array(repeating: nil, count: n)

        /// A preferred item's bid for a slot. `residual` is how far the
        /// preference sits from the slot it would ideally take.
        struct Claim {
            let item: OrbitItem
            let idealSlot: Int
            let residual: Double
            let normalizedAngle: Double
        }

        // Rank by residual so the closest claim is honored first. Without this
        // the result would depend on the order of `pinnedBundleIds`, which is
        // the order the user happened to pin things in - not something they
        // can see or reason about.
        let claims: [Claim] = preferred
            .map { entry in
                let angle = normalize(entry.preferredAngle)
                let ideal = Int((angle / step).rounded()) % n
                return Claim(
                    item: entry.item,
                    idealSlot: ideal,
                    residual: abs(smallestDifference(angle, Double(ideal) * step)),
                    normalizedAngle: angle
                )
            }
            .sorted {
                $0.residual == $1.residual
                    ? $0.normalizedAngle < $1.normalizedAngle
                    : $0.residual < $1.residual
            }

        for claim in claims {
            let slot = firstFreeSlot(from: claim.idealSlot, in: slots)
            slots[slot] = Positioned(
                item: claim.item,
                angleDegrees: Double(slot) * step,
                isAnchored: true
            )
        }

        var remaining = others.makeIterator()
        for i in 0..<n where slots[i] == nil {
            guard let item = remaining.next() else { break }
            slots[i] = Positioned(
                item: item,
                angleDegrees: Double(i) * step,
                isAnchored: false
            )
        }

        return slots.compactMap { $0 }
    }

    /// Walks outward from `ideal`, alternating clockwise and counter-clockwise,
    /// for the first unoccupied slot. Always succeeds: preferred items are
    /// themselves counted in `slots.count`, so demand never exceeds supply.
    private static func firstFreeSlot(from ideal: Int, in slots: [Positioned?]) -> Int {
        let n = slots.count
        if slots[ideal] == nil { return ideal }
        for offset in 1...n {
            let clockwise = (ideal + offset) % n
            if slots[clockwise] == nil { return clockwise }
            let counter = ((ideal - offset) % n + n) % n
            if slots[counter] == nil { return counter }
        }
        return ideal  // unreachable
    }

    /// Signed shortest angular distance from `b` to `a`, in (-180, 180].
    private static func smallestDifference(_ a: Double, _ b: Double) -> Double {
        var diff = a - b
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return diff
    }

    // MARK: - Default angle assignment

    /// Returns the angle for a new anchored item: the center of the currently
    /// largest empty arc. If no anchors exist yet, returns 0 (12 o'clock).
    /// If anchors do exist but their angles are all set, finds the largest
    /// gap between consecutive anchors and returns its midpoint.
    ///
    /// Duplicate angles in `existingAngles` are tolerated. They occur in
    /// practice: two pinned apps can end up sharing an angle, and `compute`
    /// has no duplicate handling, so it renders them stacked on the same
    /// point. A new anchor must not be placed on top of them as well.
    static func nextAnchorAngle(existingAngles: [Double]) -> Double {
        if existingAngles.isEmpty { return 0 }

        let sorted = existingAngles.map(normalize).sorted()
        if sorted.count == 1 {
            // Place directly opposite the single existing anchor.
            return normalize(sorted[0] + 180)
        }

        var bestStart: Double = sorted[0]
        var bestSize: Double = 0
        for i in 0..<sorted.count {
            let next = sorted[(i + 1) % sorted.count]
            let raw = next - sorted[i]
            // Only a negative difference is the wrap past 12 o'clock and needs
            // +360. A zero difference means two anchors share an angle; adding
            // 360 there would report the narrowest possible gap as the widest
            // one and hand the caller a midpoint sitting on top of an existing
            // anchor.
            let size = raw < 0 ? raw + 360 : raw
            if size > bestSize {
                bestSize = size
                bestStart = sorted[i]
            }
        }
        // Every anchor is at the same angle, so there is no empty arc to
        // measure. Opposite is the only placement that is not a collision.
        guard bestSize > 0 else { return normalize(sorted[0] + 180) }
        return normalize(bestStart + bestSize / 2)
    }

    // MARK: - Private helpers

    private static func normalize(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }
}
