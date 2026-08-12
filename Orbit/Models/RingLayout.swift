import Foundation

/// Pure-data layout engine for the Orbit ring.
///
/// Produces a clockwise-sorted list of `Positioned` items given the
/// user-configured anchored items (pinned apps + the dictation tile) with
/// their stored angles, plus the set of non-pinned running apps that need to
/// fill the gaps between anchors.
///
/// Angles are in degrees with 0° at the 12 o'clock position, increasing
/// clockwise. This matches what users expect when they think "position on a
/// clock face" and what `LayoutPreviewView` renders during the drag UI.
enum RingLayout {
    struct Positioned: Equatable {
        let item: OrbitItem
        let angleDegrees: Double
        let isAnchored: Bool
    }

    /// Lay out `anchoredItems` at their stored angles and distribute
    /// `nonPinned` items proportionally across the gaps between them.
    ///
    /// Output is sorted clockwise from 12 o'clock, so the returned indices can
    /// drive scroll-to-rotate, arrow-key navigation, and selection math
    /// exactly the same way as the previous even-distribution behavior.
    static func compute(
        anchoredItems: [(item: OrbitItem, angleDegrees: Double)],
        nonPinned: [OrbitItem]
    ) -> [Positioned] {
        // No anchors at all → fall back to even distribution. This preserves
        // today's behavior for users who haven't configured any pinned apps
        // and haven't enabled dictation.
        if anchoredItems.isEmpty {
            return evenDistribution(nonPinned)
        }

        // Normalize angles to [0, 360) and sort clockwise.
        let anchors = anchoredItems
            .map { ($0.item, normalize($0.angleDegrees)) }
            .sorted { $0.1 < $1.1 }

        // Anchored-only: no gap-filling needed.
        guard !nonPinned.isEmpty else {
            return anchors.map { Positioned(item: $0.0, angleDegrees: $0.1, isAnchored: true) }
        }

        // Compute gap sizes between consecutive anchors (with wrap-around).
        // If there is only one anchor, the "gap" is the full 360° starting
        // just after the anchor itself.
        struct Gap {
            let startAngle: Double   // degrees, exclusive of the anchor at this angle
            let size: Double         // degrees
            var count: Int = 0       // how many non-pinned items land here
        }

        var gaps: [Gap] = []
        for (i, anchor) in anchors.enumerated() {
            let next = anchors[(i + 1) % anchors.count]
            let rawSize = next.1 - anchor.1
            let size = rawSize > 0 ? rawSize : rawSize + 360
            gaps.append(Gap(startAngle: anchor.1, size: size))
        }

        // Distribute non-pinned items proportional to each gap's share of
        // the total gap arc. Total gap arc equals 360° because anchors are
        // infinitely thin — their "size" is 0.
        let totalSize = gaps.reduce(0) { $0 + $1.size }
        let n = nonPinned.count

        let floored: [Double] = gaps.map { Double(n) * $0.size / totalSize }
        for i in 0..<gaps.count {
            gaps[i].count = Int(floored[i].rounded(.down))
        }

        // Hand out leftover slots to the gaps with the largest fractional
        // remainders. Guarantees the sum matches `n` exactly.
        var leftover = n - gaps.reduce(0) { $0 + $1.count }
        if leftover > 0 {
            let order = (0..<gaps.count).sorted {
                (floored[$0] - Double(gaps[$0].count)) > (floored[$1] - Double(gaps[$1].count))
            }
            for i in order {
                if leftover == 0 { break }
                gaps[i].count += 1
                leftover -= 1
            }
        }

        // Place anchors and non-pinned items, walking clockwise.
        var result: [Positioned] = []
        var nonPinnedCursor = 0

        for (i, anchor) in anchors.enumerated() {
            result.append(Positioned(item: anchor.0, angleDegrees: anchor.1, isAnchored: true))
            let gap = gaps[i]
            if gap.count > 0 {
                // Evenly space items inside the gap, leaving equal margins
                // on both sides so they don't visually collide with the
                // anchors at the gap's endpoints.
                let step = gap.size / Double(gap.count + 1)
                for j in 1...gap.count {
                    let angle = normalize(gap.startAngle + step * Double(j))
                    result.append(
                        Positioned(
                            item: nonPinned[nonPinnedCursor],
                            angleDegrees: angle,
                            isAnchored: false
                        )
                    )
                    nonPinnedCursor += 1
                }
            }
        }

        // Safety: in the unlikely case the proportional math left items over,
        // stuff them at the end. Shouldn't happen with the remainder fixup
        // above, but guarding against arithmetic surprises is cheap.
        while nonPinnedCursor < nonPinned.count {
            result.append(
                Positioned(
                    item: nonPinned[nonPinnedCursor],
                    angleDegrees: normalize(Double(nonPinnedCursor) * 360 / Double(nonPinned.count)),
                    isAnchored: false
                )
            )
            nonPinnedCursor += 1
        }

        return result
    }

    // MARK: - Default angle assignment

    /// Returns the angle for a new anchored item: the center of the currently
    /// largest empty arc. If no anchors exist yet, returns 0 (12 o'clock).
    /// If anchors do exist but their angles are all set, finds the largest
    /// gap between consecutive anchors and returns its midpoint.
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
            let size = raw > 0 ? raw : raw + 360
            if size > bestSize {
                bestSize = size
                bestStart = sorted[i]
            }
        }
        return normalize(bestStart + bestSize / 2)
    }

    // MARK: - Private helpers

    private static func normalize(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Even distribution for the empty-anchors fallback. Matches the old
    /// `angleForIndex` behavior so users who haven't configured any anchors
    /// see exactly the same ring as before the feature.
    private static func evenDistribution(_ items: [OrbitItem]) -> [Positioned] {
        guard !items.isEmpty else { return [] }
        let slice = 360.0 / Double(items.count)
        return items.enumerated().map { index, item in
            Positioned(
                item: item,
                angleDegrees: normalize(slice * Double(index)),
                isAnchored: false
            )
        }
    }
}
