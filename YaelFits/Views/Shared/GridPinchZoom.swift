import SwiftUI

/// Shared pinch-zoom engine for column-grid surfaces (archive grid,
/// calendar). One place owns the mechanics both surfaces must agree on —
/// they previously carried near-identical copies that drifted:
///
/// - live scale under the fingers, anchored at the pinch focal point
/// - column stepping mid-pinch with a selection tick
/// - rubber-banding past the column limits (0.28 resistance) so the
///   extremes still overshoot and spring back
/// - underdamped settle on release
/// - SIMULTANEOUS gesture (priority can't preempt the parent ScrollView's
///   pan — a high-priority magnify raced the scroll and usually lost)
/// - whole-surface `contentShape` so a finger landing on empty cells or
///   gaps still counts toward the magnify (sparse calendars made the
///   pinch feel like it worked "1 in 6" without this)
/// - `isPinching` lingers 0.18s past release so the finger-lift is never
///   read as a tap by cell tap handlers
struct GridPinchZoomState {
    var scale: CGFloat = 1
    var anchor: UnitPoint = .center
    var isPinching = false
    var startColumns: Int?
    /// Armed while the pinch is pushed past the biggest cells (raw column
    /// value below `zoomPastMinThreshold`). Surfaces with a "final stop"
    /// (the archive's zoom-into-carousel) receive it in `onEnded`.
    var zoomedPastMin = false
}

private struct GridPinchZoomModifier: ViewModifier {
    @Binding var state: GridPinchZoomState
    let minColumns: Int
    let maxColumns: Int
    let columnCount: Int
    let setColumnCount: (Int) -> Void
    /// Raw column value below which `zoomedPastMin` arms (with one medium
    /// haptic at the crossing). nil = no final stop.
    var zoomPastMinThreshold: Double?
    /// Fired on release with whether the pinch ended pushed past the
    /// final stop. Runs after the spring-settle has been scheduled.
    var onEnded: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        content
            .scaleEffect(state.scale, anchor: state.anchor)
            .contentShape(Rectangle())
            .simultaneousGesture(gesture)
    }

    private var gesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                state.isPinching = true
                state.anchor = value.startAnchor   // finger midpoint
                if state.startColumns == nil { state.startColumns = columnCount }
                let start = Double(state.startColumns ?? columnCount)
                // Continuous desired column count (zoom out → bigger
                // cells → fewer columns).
                let raw = start / Double(value.magnification)

                if let threshold = zoomPastMinThreshold {
                    let arming = raw < threshold
                    if arming != state.zoomedPastMin {
                        state.zoomedPastMin = arming
                        if arming {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    }
                }

                let lo = Double(minColumns), hi = Double(maxColumns)
                let effective: Double
                if raw < lo { effective = lo - (lo - raw) * 0.28 }
                else if raw > hi { effective = hi + (raw - hi) * 0.28 }
                else { effective = raw }
                let whole = min(maxColumns, max(minColumns, Int(raw.rounded())))
                if whole != columnCount {
                    setColumnCount(whole)   // steps 2→3→4 mid-pinch
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                // Compensating scale relative to the (possibly just
                // stepped) column count — overshoots past the limits
                // become the bounce on release.
                state.scale = CGFloat(Double(whole) / effective)
            }
            .onEnded { _ in
                state.startColumns = nil
                // Settle with an underdamped spring so the end of the
                // zoom has a light, organic bounce.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.62)) {
                    state.scale = 1
                }
                // Keep `isPinching` true a beat longer so the finger-
                // lift doesn't register as a tap and scrolling doesn't
                // snap back mid-settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    state.isPinching = false
                }
                let past = state.zoomedPastMin
                state.zoomedPastMin = false
                onEnded?(past)
            }
    }
}

extension View {
    func gridPinchZoom(
        _ state: Binding<GridPinchZoomState>,
        minColumns: Int,
        maxColumns: Int,
        columnCount: Int,
        setColumnCount: @escaping (Int) -> Void,
        zoomPastMinThreshold: Double? = nil,
        onEnded: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(GridPinchZoomModifier(
            state: state,
            minColumns: minColumns,
            maxColumns: maxColumns,
            columnCount: columnCount,
            setColumnCount: setColumnCount,
            zoomPastMinThreshold: zoomPastMinThreshold,
            onEnded: onEnded
        ))
    }
}
