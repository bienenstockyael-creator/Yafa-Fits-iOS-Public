import SwiftUI
import ImageIO

// Lightweight 360° frame spinner for the clip — the full app's
// FrameLoader/RotatableOutfitImage stack drags in local storage,
// stores and actors the clip doesn't need. This one streams frames
// from the CDN, keeps the COMPRESSED bytes (a few MB), and decodes
// on demand through a small LRU so memory stays flat.
struct FrameSpinner: View {
    let fit: ClipFit

    @State private var loader: FrameSequence?
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
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard let loader, loader.loadedCount > 1 else { return }
                        dragging = true
                        let now = ProcessInfo.processInfo.systemUptime
                        let last = lastDragX ?? value.translation.width
                        let dx = value.translation.width - last
                        let dt = max(0.001, now - (lastDragTime ?? now))
                        lastDragX = value.translation.width
                        lastDragTime = now
                        let dir: Double = fit.isRotationReversed ? -1 : 1
                        let frameDelta = dir * Double(dx / pixelsPerFrame)
                        framePos = wrap(framePos + frameDelta)
                        // Normalize the per-event delta to a per-60fps
                        // tick velocity so the release fling feels
                        // identical at any touch event rate — the
                        // app's exact rule.
                        velocity = frameDelta * (0.01667 / dt)
                        show(frame: Int(framePos))
                    }
                    .onEnded { _ in
                        dragging = false
                        lastDragX = nil
                        lastDragTime = nil
                    }
            )
        }
        .task(id: fit.outfitId) {
            let sequence = FrameSequence(fit: fit)
            loader = sequence
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
                if abs(velocity) > velocityThreshold {
                    velocity *= friction
                    let next = wrap(framePos + velocity)
                    guard sequence.hasFrame(Int(next)) else { continue }
                    framePos = next
                } else {
                    velocity = 0
                    let dir: Double = fit.isRotationReversed ? -1 : 1
                    let next = wrap(framePos + dir * autoSpinPerTick)
                    guard sequence.hasFrame(Int(next)) else { continue }
                    framePos = next
                }
                show(frame: Int(framePos))
            }
        }
    }

    private func wrap(_ value: Double) -> Double {
        let n = Double(max(fit.frameCount, 1))
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
    private let fit: ClipFit
    private var data: [Int: Data] = [:]
    private var decoded: [Int: UIImage] = [:]
    private var decodeOrder: [Int] = []
    private let decodeCacheLimit = 40

    init(fit: ClipFit) {
        self.fit = fit
    }

    var loadedCount: Int { data.count }
    func hasFrame(_ index: Int) -> Bool { data[index] != nil }

    private func url(_ index: Int) -> URL? {
        URL(string: "https://\(fit.frameBase)\(String(format: "%05d", index)).\(fit.frameExt)")
            ?? URL(string: "\(fit.frameBase)\(String(format: "%05d", index)).\(fit.frameExt)")
    }

    private func fetch(_ index: Int) async {
        guard data[index] == nil else { return }
        let raw = fit.frameBase.hasPrefix("http") ? fit.frameBase : "https://" + fit.frameBase
        guard let url = URL(string: "\(raw)\(String(format: "%05d", index)).\(fit.frameExt)") else { return }
        guard let (bytes, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        data[index] = bytes
    }

    func prefetchAll() async {
        // Modest parallelism — the clip shares the phone's radio with
        // whatever invoked it.
        let total = fit.frameCount
        var index = 0
        while index < total, !Task.isCancelled {
            let batch = Array(index..<min(index + 6, total))
            await withTaskGroup(of: Void.self) { group in
                for i in batch {
                    group.addTask { await self.fetch(i) }
                }
            }
            index += 6
        }
    }

    func frame(_ index: Int) async -> UIImage? {
        if let cached = decoded[index] { return cached }
        if data[index] == nil { await fetch(index) }
        guard let bytes = data[index] else { return nil }
        // Downsampled decode (display is ~400pt) keeps each frame small.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cg)
        decoded[index] = image
        decodeOrder.append(index)
        if decodeOrder.count > decodeCacheLimit {
            let evict = decodeOrder.removeFirst()
            decoded.removeValue(forKey: evict)
        }
        return image
    }
}
