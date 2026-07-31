import SwiftUI
import ImageIO

// Lightweight 360° frame spinner for the clip — the full app's
// FrameLoader/RotatableOutfitImage stack drags in local storage,
// stores and actors the clip doesn't need. This one streams frames
// from the CDN, keeps the COMPRESSED bytes (a few MB), and decodes
// on demand through a small LRU so memory stays flat.
//
// `fit` is OPTIONAL so the carousel can keep ONE stable view type
// per slide (like the app's RotatableOutfitImage): a nil fit renders
// just the placeholder with no loader — flipping a slide live is a
// prop change, never a view-identity change. Identity churn was the
// root of the "outfits ghost-crossfade instead of sliding" bug: the
// old slide subtree got removed+reinserted mid-page-animation and
// rendered as a fading ghost at the old strip position.
struct FrameSpinner: View {
    let fit: ClipFit?
    /// Shown until the first frame decodes — the carousel passes the
    /// slide's cached first-frame thumbnail here so the static→live
    /// swap is pixel-invisible instead of a blank flash.
    var placeholder: UIImage? = nil
    /// Feed cards idle-spin; the app's carousel does NOT — the outfit
    /// rests until scrubbed, and a fling coasts down and stops.
    var autoSpins: Bool = true
    /// Fired when a scrub drag ends, with (netTranslation,
    /// monotonicityRatio). The carousel uses the app's ScrubSwipe
    /// rule — a long, mostly-one-direction drag flips the page,
    /// a back-and-forth scrub never does.
    var onScrubRelease: ((CGFloat, CGFloat) -> Void)? = nil
    /// When set, drags that start in the 60pt edge margins or run
    /// mostly vertical are ROUTED to the host instead of scrubbing —
    /// the app's RotatableOutfitImage edge-inset/direction rule, so
    /// page-drags, swipe-up (card) and swipe-down (dismiss) work over
    /// the outfit. A nil-fit (inactive) slide routes EVERY drag.
    var onPassThroughChanged: ((CGSize) -> Void)? = nil
    var onPassThroughEnded: ((CGSize, CGSize) -> Void)? = nil

    private static let passEdgeInset: CGFloat = 60

    private enum DragRoute { case undecided, scrub, pass }
    @State private var route: DragRoute = .undecided

    @State private var loader: FrameSequence?
    @State private var dragMinX: CGFloat = 0
    @State private var dragMaxX: CGFloat = 0
    @State private var displayed: UIImage?
    @State private var framePos: Double = 0
    @State private var velocity: Double = 0
    @State private var dragging = false
    @State private var lastDragX: CGFloat?
    @State private var lastDragTime: TimeInterval?

    // FrameConfig physics, verbatim (same constants the app and the
    // web card use): drag scrub -> release fling -> friction coast ->
    // idle auto-spin.
    private let autoSpinPerTick = 0.6
    private let pixelsPerFrame: CGFloat = 1.5
    private let friction = 0.985
    private let velocityThreshold = 0.3

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let displayed {
                    Image(uiImage: displayed)
                        .resizable()
                        .scaledToFit()
                } else if let placeholder {
                    Image(uiImage: placeholder)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if route == .undecided {
                            if fit == nil, onPassThroughChanged != nil {
                                // Inactive slide: everything pages.
                                route = .pass
                            } else if onPassThroughChanged != nil {
                                let w = abs(value.translation.width)
                                let h = abs(value.translation.height)
                                let inEdge = value.startLocation.x < Self.passEdgeInset
                                    || value.startLocation.x > geo.size.width - Self.passEdgeInset
                                if inEdge {
                                    route = .pass
                                } else if w < 8, h < 8 {
                                    // Too early to judge direction.
                                    return
                                } else {
                                    route = h > w ? .pass : .scrub
                                }
                            } else {
                                route = .scrub
                            }
                        }

                        switch route {
                        case .pass:
                            onPassThroughChanged?(value.translation)
                        case .scrub:
                            // Alive from the FIRST touch — even before
                            // any frames arrive, position tracks the
                            // finger so the spin picks up mid-gesture
                            // the moment frames land (a dead first
                            // second read as a stall).
                            guard let fit, let loader else { return }
                            if !dragging {
                                dragMinX = value.translation.width
                                dragMaxX = value.translation.width
                            }
                            dragMinX = min(dragMinX, value.translation.width)
                            dragMaxX = max(dragMaxX, value.translation.width)
                            dragging = true
                            let now = ProcessInfo.processInfo.systemUptime
                            let last = lastDragX ?? value.translation.width
                            let dx = value.translation.width - last
                            let dt = max(0.001, now - (lastDragTime ?? now))
                            lastDragX = value.translation.width
                            lastDragTime = now
                            let dir: Double = fit.isRotationReversed ? -1 : 1
                            let frameDelta = dir * Double(dx / pixelsPerFrame)
                            // Position ALWAYS tracks the finger at
                            // full speed — only the displayed image
                            // quantizes to the nearest loaded frame.
                            // Sparse fits spin at the same velocity
                            // as loaded ones, just at a lower frame
                            // rate that sharpens as frames stream.
                            framePos = wrap(framePos + frameDelta)
                            // Normalize the per-event delta to a per-60fps
                            // tick velocity so the release fling feels
                            // identical at any touch event rate — the
                            // app's exact rule.
                            velocity = frameDelta * (0.01667 / dt)
                            if let display = loader.nearestLoadedFrame(to: Int(framePos), radius: 3) {
                                show(frame: display)
                            }
                        case .undecided:
                            break
                        }
                    }
                    .onEnded { value in
                        defer { route = .undecided }
                        switch route {
                        case .pass:
                            onPassThroughEnded?(value.translation, value.predictedEndTranslation)
                        case .scrub:
                            dragging = false
                            lastDragX = nil
                            lastDragTime = nil
                            let net = value.translation.width
                            let range = max(1, dragMaxX - dragMinX)
                            onScrubRelease?(net, abs(net) / range)
                        case .undecided:
                            break
                        }
                    }
            )
        }
        .task(id: fit?.outfitId) {
            guard let fit else {
                // Inactive: shed the loader and rest on the placeholder.
                loader = nil
                displayed = nil
                framePos = 0
                velocity = 0
                return
            }
            // Registry-backed: frames survive paging away and back,
            // and a neighbor pre-streamed sequence is already warm.
            let sequence = FrameSequence.activate(for: fit)
            loader = sequence
            framePos = 0
            velocity = 0
            // First frame ASAP, then the rest stream in behind it.
            if let first = await sequence.frame(0) {
                displayed = first
            }
            await sequence.prefetchAll()
            // The app's tick loop: fling coasts down on friction
            // until it drops below threshold, then the idle
            // auto-spin takes over — advancing only onto frames
            // that have arrived (the progressive-spin rule).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_666_667)
                guard !dragging, fit.frameCount > 1 else { continue }
                // Physics never waits for the network: position
                // advances at full velocity every tick, and only the
                // DISPLAY quantizes to the nearest loaded frame
                // (briefly holding the last image at the streaming
                // frontier). Sparse fits spin at the exact same
                // velocity as fully-loaded ones — just at a lower
                // frame rate until the pyramid fills in.
                if abs(velocity) > velocityThreshold {
                    velocity *= friction
                    framePos = wrap(framePos + velocity)
                } else {
                    velocity = 0
                    // The carousel rests when idle — only feed cards
                    // idle-spin.
                    guard autoSpins else { continue }
                    let dir: Double = fit.isRotationReversed ? -1 : 1
                    framePos = wrap(framePos + dir * autoSpinPerTick)
                }
                if let display = sequence.nearestLoadedFrame(to: Int(framePos), radius: 3) {
                    show(frame: display)
                }
            }
        }
    }

    private func wrap(_ value: Double) -> Double {
        let n = Double(max(fit?.frameCount ?? 1, 1))
        return (value.truncatingRemainder(dividingBy: n) + n).truncatingRemainder(dividingBy: n)
    }

    private func show(frame: Int) {
        guard let loader else { return }
        Task {
            if let img = await loader.frame(frame) {
                displayed = img
            }
        }
    }
}

/// Compressed-bytes store + bounded decode cache.
@MainActor
final class FrameSequence {
    // MARK: Shared registry — sequences survive paging.
    //
    // The carousel used to discard a fit's sequence the moment you
    // swiped away and re-download from zero on return; and a freshly
    // paged fit started with nothing. The registry keeps the last few
    // sequences alive (compressed bytes are cheap); only the current
    // fit keeps DECODED bitmaps — everyone else's are purged on
    // switch and re-decoded on demand.
    private static var registry: [String: FrameSequence] = [:]
    private static var registryOrder: [String] = []

    /// The sequence a live spinner should drive. Purges every OTHER
    /// sequence's decoded bitmaps — only the active fit holds them.
    static func activate(for fit: ClipFit) -> FrameSequence {
        for (id, seq) in registry where id != fit.outfitId {
            seq.purgeDecoded()
        }
        return shared(for: fit)
    }

    /// Registry lookup WITHOUT the purge — background warming
    /// (neighbor pass-1 streaming) must not evict the current fit's
    /// decoded frames.
    static func shared(for fit: ClipFit) -> FrameSequence {
        if let existing = registry[fit.outfitId] {
            registryOrder.removeAll { $0 == fit.outfitId }
            registryOrder.append(fit.outfitId)
            return existing
        }
        let fresh = FrameSequence(fit: fit)
        registry[fit.outfitId] = fresh
        registryOrder.append(fit.outfitId)
        while registryOrder.count > 4 {
            let evicted = registryOrder.removeFirst()
            registry.removeValue(forKey: evicted)
        }
        return fresh
    }

    private func purgeDecoded() {
        decoded.removeAll()
        decodeOrder.removeAll()
    }

    private let fit: ClipFit
    private var data: [Int: Data] = [:]
    private var decoded: [Int: UIImage] = [:]
    private var decodeOrder: [Int] = []
    private var pass1Started = false
    private var fullPrefetchStarted = false
    // 24 × ~3MB decoded ≈ 72MB ceiling per live spinner. Two can be
    // alive at once (main card under a presented carousel page) — 40
    // was fine solo but risked jetsam in the clip's budget once the
    // profile carousel shipped.
    private let decodeCacheLimit = 24
    private var memoryWarningObserver: NSObjectProtocol?

    init(fit: ClipFit) {
        self.fit = fit
        // Under memory pressure, dump decoded bitmaps (recreatable
        // from the compressed store) before the OS dumps us.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.decoded.removeAll()
                self?.decodeOrder.removeAll()
            }
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    var loadedCount: Int { data.count }
    func hasFrame(_ index: Int) -> Bool { data[index] != nil }

    private func fetch(_ index: Int) async {
        guard data[index] == nil else { return }
        let raw = fit.frameBase.hasPrefix("http") ? fit.frameBase : "https://" + fit.frameBase
        guard let url = URL(string: "\(raw)\(String(format: "%05d", index)).\(fit.frameExt)") else { return }
        guard let (bytes, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        data[index] = bytes
    }

    func prefetchAll() async {
        // Pyramid order: every 4th frame first (the whole circle
        // becomes spinnable at quarter frame rate almost
        // immediately), then the remaining evens (half rate), then
        // the odds. Paired with nearest-loaded-frame display, early
        // interaction feels like a low-fps spin that sharpens as
        // frames stream in — never a wall.
        guard !fullPrefetchStarted else { return }
        fullPrefetchStarted = true
        let total = fit.frameCount
        var order: [Int] = []
        order.append(contentsOf: stride(from: 0, to: total, by: 4))
        order.append(contentsOf: stride(from: 2, to: total, by: 4))
        order.append(contentsOf: stride(from: 1, to: total, by: 2))
        await prefetch(order: order)
    }

    /// Quarter-rate coverage only — streamed for NEIGHBOR slides in
    /// the background so a page flip lands already spinnable.
    func prefetchPass1() async {
        guard !pass1Started, !fullPrefetchStarted else { return }
        pass1Started = true
        await prefetch(order: Array(stride(from: 0, to: fit.frameCount, by: 4)))
    }

    private func prefetch(order: [Int]) async {
        // Modest parallelism — the clip shares the phone's radio with
        // whatever invoked it.
        var cursor = 0
        while cursor < order.count, !Task.isCancelled {
            let batch = Array(order[cursor..<min(cursor + 6, order.count)])
            await withTaskGroup(of: Void.self) { group in
                for i in batch {
                    group.addTask { await self.fetch(i) }
                }
            }
            cursor += 6
        }
    }

    /// Nearest fetched frame within `radius` of the target (wrapping).
    /// After the stride-4 pass no target is more than 2 away, so the
    /// spin can traverse the full circle before every frame lands.
    func nearestLoadedFrame(to index: Int, radius: Int = 2) -> Int? {
        let n = max(fit.frameCount, 1)
        let base = ((index % n) + n) % n
        if data[base] != nil { return base }
        for d in 1...max(1, radius) {
            let up = (base + d) % n
            if data[up] != nil { return up }
            let down = (((base - d) % n) + n) % n
            if data[down] != nil { return down }
        }
        return nil
    }

    func frame(_ index: Int) async -> UIImage? {
        if let cached = decoded[index] { return cached }
        if data[index] == nil { await fetch(index) }
        guard let bytes = data[index] else { return nil }
        // Decode OFF the main actor — first-time decodes during a
        // scrub were hitching the 60fps loop.
        guard let image = await Task.detached(priority: .userInitiated, operation: {
            Self.decode(bytes)
        }).value else { return nil }
        decoded[index] = image
        decodeOrder.append(index)
        if decodeOrder.count > decodeCacheLimit {
            let evict = decodeOrder.removeFirst()
            decoded.removeValue(forKey: evict)
        }
        return image
    }

    /// Downsampled decode (display is ~400pt) keeps each frame small.
    private nonisolated static func decode(_ bytes: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
