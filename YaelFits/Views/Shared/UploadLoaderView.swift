import Lottie
import SwiftUI

// MARK: - Shimmer text

/// Renders text with a soft highlight that sweeps left→right on repeat.
/// Uses an animated LinearGradient as the foreground so no overlays
/// or masks are needed — stays crisp at any font size.
struct ShimmerText: View {
    let text: String
    let font: Font
    let tracking: CGFloat

    @State private var offset: CGFloat = -0.5

    var body: some View {
        Text(text)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(AppPalette.textFaint)
            .overlay {
                GeometryReader { geo in
                    // Static gradient — only its position moves.
                    // Starts fully off the left edge, ends fully off the right.
                    // Loop reset is invisible because band is off-screen at both ends.
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.88), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5, height: geo.size.height)
                    .offset(x: offset * geo.size.width)
                }
                .mask(
                    Text(text)
                        .font(font)
                        .tracking(tracking)
                )
            }
            .onAppear { startShimmer() }
            .onChange(of: text) { _, _ in startShimmer() }
    }

    private func startShimmer() {
        offset = -0.5
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            offset = 1.0
        }
    }
}

// MARK: - Available animation names

private let starAnimNames: [String] = (1...5).compactMap { i in
    let name = "star-anim-\(i)"
    // Only include if the file actually exists in the bundle
    return Bundle.main.url(forResource: name, withExtension: "json") != nil ? name : nil
}

// MARK: - Star particle model

private struct StarParticle: Identifiable {
    let id = UUID()
    let animName: String
    let x: CGFloat   // 0–1 relative to container
    let y: CGFloat
    let scale: CGFloat
}

// MARK: - Ambient star field

struct GenerationStarField: View {
    private static let maxConcurrent = 5
    private static let spawnInterval: TimeInterval = 0.38
    private static let particleLifetime: TimeInterval = 1.8
    // Circle radius as fraction of the shorter screen dimension
    private static let circleRadius: CGFloat = 0.33

    @State private var particles: [StarParticle] = []
    @State private var spawnTask: Task<Void, Never>?
    @State private var circleAngle: Double = 0
    @State private var containerSize: CGSize = .zero
    @State private var lastDragSpawn: Date = .distantPast

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { p in
                    NeonStarView(animName: p.animName)
                        .scaleEffect(p.scale)
                        .position(x: p.x * geo.size.width,
                                  y: p.y * geo.size.height)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: particles.map(\.id))
            .contentShape(Rectangle())
            // Drag — continuously spawn sparkles following the finger
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let now = Date()
                        guard now.timeIntervalSince(lastDragSpawn) > 0.10 else { return }
                        lastDragSpawn = now
                        let nx = (value.location.x / geo.size.width).clamped(to: 0.05...0.95)
                        let ny = (value.location.y / geo.size.height).clamped(to: 0.05...0.95)
                        spawnParticle(x: nx, y: ny)
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.25)
                    }
            )
            .onAppear {
                containerSize = geo.size
                startSpawning()
            }
        }
        .onDisappear { spawnTask?.cancel() }
    }

    private func startSpawning() {
        spawnTask?.cancel()
        spawnTask = Task {
            // Seed two immediately
            spawnOnCircle(); spawnOnCircle()

            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.spawnInterval * Double.random(in: 0.75...1.25))
                )
                guard !Task.isCancelled else { break }
                if particles.count < Self.maxConcurrent { spawnOnCircle() }
            }
        }
    }

    /// Spawns a sparkle at the next position around the circle, with slight angle jitter.
    private func spawnOnCircle() {
        circleAngle += Double.random(in: 0.55...1.1) // jitter advances so they spread
        let size = containerSize == .zero
            ? CGSize(width: 390, height: 700) : containerSize
        let r = Self.circleRadius * min(size.width, size.height)
        let rx = r / size.width
        let ry = r / size.height
        let x = (0.5 + CGFloat(cos(circleAngle)) * rx).clamped(to: 0.05...0.95)
        let y = (0.5 + CGFloat(sin(circleAngle)) * ry).clamped(to: 0.05...0.95)
        spawnParticle(x: x, y: y)
    }

    private func spawnParticle(x: CGFloat, y: CGFloat) {
        guard let name = starAnimNames.randomElement() else { return }
        let particle = StarParticle(
            animName: name,
            x: x, y: y,
            scale: CGFloat.random(in: 0.65...1.1)
        )
        particles.append(particle)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.particleLifetime))
            particles.removeAll { $0.id == particle.id }
        }
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Single neon star

private struct NeonStarView: View {
    let animName: String

    var body: some View {
        ZStack {
            // Blurred copy behind — fake glow halo
            LottieView(animation: .named(animName))
                .playing(loopMode: .playOnce)
                .frame(width: 280, height: 280)
                .blur(radius: 10)
                .opacity(0.85)

            // Sharp copy on top
            LottieView(animation: .named(animName))
                .playing(loopMode: .playOnce)
                .frame(width: 280, height: 280)
        }
    }
}

// MARK: - Legacy loader

struct UploadLoaderView: View {
    var size: CGFloat = 220
    private let lottieResourceName = "upload-loader"

    var body: some View {
        if Bundle.main.url(forResource: lottieResourceName, withExtension: "json") != nil {
            LottieView(animation: .named(lottieResourceName))
                .looping()
                .frame(width: size, height: size)
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(AppPalette.textMuted)
                .frame(width: size, height: size)
        }
    }
}
