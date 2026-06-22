import SwiftUI

/// "Add me on Yafa" share flow. Presented from the profile-home
/// share button. Mirrors the ShareCardComposer sheet pattern:
/// a card preview front-and-center, a swipeable carousel to pick
/// which outfit rides on the card, and a share CTA that hands off
/// to the system share sheet.
///
/// The card itself reuses the Mono share-card design language —
/// cardGray background, Inter Medium Italic labels 8% from the
/// edges — with profile-specific copy: "add me on Yafa!" on top,
/// the @username on the bottom, and the chosen outfit spinning in
/// the middle (drag to rotate, auto-rotates when idle).
///
/// What gets shared: the web profile card URL
/// (yafafits.com/u/{username}?o={outfitId}). The recipient sees
/// the same card rendered on the web — outfit included — plus the
/// waitlist CTA. The `o` param tells the web page which outfit to
/// feature so sender choice survives the trip.
struct ProfileShareSheet: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIndex = 0
    @State private var cardVisible = false
    /// URL being handed to the system share sheet. Set at tap
    /// time (not view-build time) so the selected outfit is
    /// guaranteed to be the one captured in the link.
    @State private var activeShareURL: URL? = nil
    /// Live horizontal drag offset while the user is swiping
    /// through outfits. Same continuous-strip mechanic as the
    /// ShareCardComposer template carousel.
    @State private var carouselDragOffset: CGFloat = 0
    /// Fractional dot position while the user is scrubbing the
    /// dot picker. nil at rest.
    @State private var dotScrubPosition: CGFloat? = nil

    private let cardGray = Color(white: 0.918)

    /// Card width is height-constrained inside the 560pt carousel
    /// area (560 - 100 shadow budget = 460 → ×342/480). Computed
    /// from UIScreen (like the composer does) so the carousel and
    /// the dot picker agree on the same step without plumbing
    /// geometry between them.
    private var cardWidthEstimate: CGFloat {
        min(UIScreen.main.bounds.width - 48, 460 * (342.0 / 480.0))
    }

    /// Distance between neighboring outfits in the strip. Smaller
    /// than the card width so the previous/next outfits peek in
    /// from the card's edges.
    private var carouselStep: CGFloat { cardWidthEstimate * 0.62 }

    /// Small, curated outfit selection: up to 3 favorites (most
    /// recent first) then latest outfits to fill, deduped, max 6.
    /// Curation beats completeness here — the full archive lives
    /// in the grid; this is a "pick your look" moment.
    ///
    /// Restricted to PUBLIC outfits: the web profile card can only
    /// feature outfits that are `is_public` in Supabase, and it
    /// silently falls back to the latest public one for anything it
    /// can't resolve. Offering private/unsynced (e.g. bundled) outfits
    /// here would let the user "pick" a look that the recipient never
    /// sees — every such pick collapses to the same fallback outfit.
    private var shareableOutfits: [Outfit] {
        let sorted = store.sortedOutfits.filter { $0.isPublic == true }
        let favorites = sorted.filter { store.likedIds.contains($0.id) }.prefix(3)
        let latest = sorted.prefix(4)
        var seen = Set<String>()
        var result: [Outfit] = []
        for outfit in Array(favorites) + Array(latest) {
            guard seen.insert(outfit.id).inserted else { continue }
            result.append(outfit)
            if result.count >= 6 { break }
        }
        return result
    }

    private var selectedOutfit: Outfit? {
        let outfits = shareableOutfits
        guard outfits.indices.contains(selectedIndex) else { return outfits.first }
        return outfits[selectedIndex]
    }

    private var shareURL: URL? {
        guard let username = store.currentProfile?.username, !username.isEmpty
        else { return nil }
        var components = URLComponents(string: "https://yafafits.com/u/\(username)")
        if let outfitId = selectedOutfit?.id {
            components?.queryItems = [URLQueryItem(name: "o", value: outfitId)]
        }
        return components?.url
    }

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.top, LayoutMetrics.medium)

                Spacer(minLength: LayoutMetrics.medium)

                cardCarousel
                    .offset(y: cardVisible ? 0 : 72)
                    .opacity(cardVisible ? 1 : 0)
                    .scaleEffect(cardVisible ? 1 : 0.88)
                    .rotation3DEffect(
                        .degrees(cardVisible ? 0 : 18),
                        axis: (x: 1, y: 0, z: 0),
                        perspective: 0.4
                    )

                pageDots
                    .padding(.top, 14)
                    .opacity(cardVisible ? 1 : 0)

                Spacer(minLength: LayoutMetrics.large)

                shareButton
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, LayoutMetrics.xLarge)
                    .opacity(cardVisible ? 1 : 0)
                    .offset(y: cardVisible ? 0 : 16)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.05)) {
                cardVisible = true
            }
        }
    }

    // MARK: - Header (matches app modal pattern)

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer()

            Text("SHARE PROFILE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: - Fixed card + outfit strip carousel

    /// The card frame (gray background + labels) stays FIXED;
    /// the outfits live in a continuous horizontal strip ABOVE
    /// the card — unclipped, so the previous/next outfits peek in
    /// from the card's edges and the drag reads as a carousel.
    /// Same continuous-offset mechanic as the ShareCardComposer's
    /// template carousel (drag moves the strip live; release
    /// snaps to the nearest index on translation/velocity
    /// thresholds).
    private var cardCarousel: some View {
        let outfits = shareableOutfits
        let step = carouselStep

        return GeometryReader { geo in
            // Budget vertical room for the drop shadow's blur
            // falloff (radius 16, y 10 → ~30pt visible extent,
            // 50pt budgeted each side for clean fade-out).
            let heightBudget = geo.size.height - 100
            let cardWidth = min(geo.size.width - 48, heightBudget * (342.0 / 480.0))
            let cardHeight = cardWidth * (480.0 / 342.0)
            let scale = cardWidth / 345.0
            // 7.5% of card width (was the Mono date's 10.4%) — the
            // profile labels are longer than a month name, so the
            // type is dialed back to let the outfit lead. Matches
            // the web ProfileShareCard's `min(7.5cqw, 30px)`.
            let labelFont = Font.custom("Inter28pt-MediumItalic", size: 26 * scale)
            let stripBaseOffset =
                geo.size.width / 2 - CGFloat(selectedIndex) * step

            // Distance of outfit i from the visible center, in
            // fractional index units. Updates live during a drag
            // so the neighbor scale/fade interpolates smoothly.
            let relativePos: (Int) -> CGFloat = { i in
                CGFloat(i) - CGFloat(selectedIndex) + carouselDragOffset / step
            }

            ZStack {
                // Fixed card.
                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                    .fill(cardGray)
                    .shadow(color: .black.opacity(0.14), radius: 16, y: 10)
                    .frame(width: cardWidth, height: cardHeight)

                Text("add me on Yafa!")
                    .font(labelFont)
                    .tracking(-1.13 * scale)
                    .foregroundStyle(.black)
                    .offset(y: -cardHeight * 0.42)
                    .allowsHitTesting(false)

                Text("@\(store.currentProfile?.username ?? "")")
                    .font(labelFont)
                    .tracking(-1.13 * scale)
                    .foregroundStyle(.black)
                    .offset(y: cardHeight * 0.42)
                    .allowsHitTesting(false)

                // Outfit strip — floats over the card, unclipped.
                // Neighbors shrink + fade by distance from center.
                ZStack {
                    ForEach(Array(outfits.enumerated()), id: \.element.id) { i, outfit in
                        let pos = relativePos(i)
                        let proximity = max(0, 1 - abs(pos))
                        RotatableOutfitImage(
                            outfit: outfit,
                            height: cardHeight * 0.64,
                            draggable: false,
                            eagerLoad: true,
                            // Only the centered outfit spins — neighbors
                            // hold still until they're swiped into the
                            // card. (RotatableOutfitImage reacts to this
                            // flag changing, so promotion on page-change
                            // starts the spin.)
                            autoRotate: i == selectedIndex
                        )
                        .scaleEffect(0.72 + 0.28 * proximity)
                        .offset(x: pos * step)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: cardHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        carouselDragOffset = value.translation.width
                    }
                    .onEnded { value in
                        let translation = value.translation.width
                        let velocity = value.predictedEndTranslation.width
                        var newIndex = selectedIndex
                        if translation < -50 || velocity < -200 {
                            newIndex = min(selectedIndex + 1, outfits.count - 1)
                        } else if translation > 50 || velocity > 200 {
                            newIndex = max(selectedIndex - 1, 0)
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            selectedIndex = newIndex
                            carouselDragOffset = 0
                        }
                    }
            )
        }
        .frame(height: 560)
    }

    // MARK: - Dot picker (matches ShareCardComposer.templatePicker)

    /// Fractional "lens" position for the dot magnification. A dot
    /// scrub wins; otherwise tracks the selected index plus any
    /// in-progress strip drag so the lens slides with the swipe.
    private var pickerActivePosition: CGFloat {
        if let scrub = dotScrubPosition { return scrub }
        return CGFloat(selectedIndex) + (-carouselDragOffset / carouselStep)
    }

    private var pageDots: some View {
        let outfits = shareableOutfits
        // Small / flat at rest; bigger dots, wider spacing, and the
        // magnifying lens only while interacting (scrubbing the
        // dots or dragging the strip).
        let isActive = dotScrubPosition != nil || abs(carouselDragOffset) > 0.5
        let dotSize: CGFloat = isActive ? 6 : 4
        let dotSpacing: CGFloat = isActive ? 18 : 11
        let maxScale: CGFloat = isActive ? 2.4 : 1.0
        let spread: CGFloat = 2.0
        let active = pickerActivePosition
        let activeIntClamped = Int(round(
            max(0, min(CGFloat(outfits.count - 1), active))
        ))

        return GeometryReader { geo in
            let totalWidth = CGFloat(max(0, outfits.count - 1)) * dotSpacing
            let leadingX = (geo.size.width - totalWidth) / 2

            ZStack {
                ForEach(outfits.indices, id: \.self) { i in
                    let centerX = leadingX + CGFloat(i) * dotSpacing
                    let d = abs(active - CGFloat(i))
                    let proximity = max(0, 1 - d / spread)
                    let scale = 1 + (maxScale - 1) * proximity * proximity
                    let isSelected = i == activeIntClamped

                    Circle()
                        .fill(isSelected ? AppPalette.textSecondary : AppPalette.textFaint)
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(scale)
                        .position(x: centerX, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard outfits.count > 1 else { return }
                        let relativeX = value.location.x - leadingX
                        let frac = relativeX / dotSpacing
                        let clamped = max(0, min(CGFloat(outfits.count - 1), frac))
                        dotScrubPosition = clamped

                        let snapped = Int(round(clamped))
                        if snapped != selectedIndex {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                selectedIndex = snapped
                            }
                        }
                    }
                    .onEnded { _ in
                        // Let the lens settle back onto the selected
                        // outfit — the spring is what produces the
                        // "magnetism" feel.
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            dotScrubPosition = nil
                        }
                    }
            )
        }
        .frame(height: 36)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: isActive)
    }

    // MARK: - Share CTA

    /// Plain Button + manual UIActivityViewController instead of
    /// ShareLink: the action closure reads `shareURL` at TAP time
    /// (guaranteeing the currently-selected outfit is in the link)
    /// and gives us a reliable hook for the analytics event —
    /// `.simultaneousGesture` never fires on ShareLink taps.
    private var shareButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            guard let url = shareURL else { return }
            Analytics.log("profile_share_tapped", properties: [
                "outfit_id": .string(selectedOutfit?.id ?? "none"),
                "url": .string(url.absoluteString)
            ])
            activeShareURL = url
        } label: {
            Text("SHARE")
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(AppPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .appCapsule(shadowRadius: 6, shadowY: 3)
        }
        .buttonStyle(.plain)
        .disabled(shareURL == nil)
        .sheet(isPresented: Binding(
            get: { activeShareURL != nil },
            set: { if !$0 { activeShareURL = nil } }
        )) {
            if let url = activeShareURL {
                ShareActivityView(items: [url])
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

/// Thin UIActivityViewController wrapper for SwiftUI.
private struct ShareActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
