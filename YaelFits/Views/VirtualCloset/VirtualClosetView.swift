import SwiftUI

/// Virtual Closet — avatar centered, three horizontal carousels overlapping
/// the avatar at chest / hip / feet zones. The currently-centred item in
/// each carousel is the one "applied" to the avatar; neighbour items peek
/// past either side of the avatar so the user can see what's coming next.
struct VirtualClosetView: View {
    @Environment(OutfitStore.self) private var store

    let userId: UUID
    /// Pre-generated avatar (passed in from the onboarding flow). Treated as
    /// optional so the closet can degrade gracefully if the avatar is still
    /// loading from storage.
    var avatar: UIImage?
    var onClose: () -> Void

    @State private var library: [ProductLibraryItem] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var topSelectionID: ClosetItem.ID?
    @State private var bottomSelectionID: ClosetItem.ID?
    @State private var shoesSelectionID: ClosetItem.ID?
    /// Fallback avatar loaded from disk if the parent view didn't pass one in.
    /// Keeps the closet self-sufficient so a returning user always sees their
    /// saved avatar, regardless of how they got into this sheet.
    @State private var loadedAvatar: UIImage?

    /// The most recent dressed-avatar generation. When non-nil, replaces the
    /// original avatar on stage so the user can iteratively re-dress without
    /// leaving this view.
    @State private var dressedAvatar: UIImage?
    /// Snapshot of the selection IDs that produced `dressedAvatar`. Used to
    /// fade those exact items out of their carousels (since the dressed
    /// avatar is already wearing them) and to flip the action button between
    /// "DRESS AVATAR" (pending change) and "SAVE OUTFIT" (already applied).
    @State private var dressedSelections: ClosetSelections?

    @State private var isDressing = false
    @State private var dressStatusDetail = "Dressing your avatar"
    @State private var dressError: String?
    @State private var dressTask: Task<Void, Never>?
    @State private var savedToRemixes = false
    @State private var showsRemixArchive = false

    /// The original (clean) avatar — what we always feed back into nano-banana
    /// so re-dressing doesn't compound artifacts from previous generations.
    private var sourceAvatar: UIImage? { avatar ?? loadedAvatar }
    /// The avatar shown on stage. Prefers the dressed result when available.
    private var displayAvatar: UIImage? { dressedAvatar ?? sourceAvatar }

    private var currentSelections: ClosetSelections {
        ClosetSelections(top: topSelectionID, bottom: bottomSelectionID, shoes: shoesSelectionID)
    }
    private var hasAnySelection: Bool {
        topSelectionID != nil || bottomSelectionID != nil || shoesSelectionID != nil
    }
    private var selectionMatchesDressed: Bool {
        dressedSelections != nil && dressedSelections == currentSelections
    }

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                stage
                dressButton
            }
            .padding(.bottom, LayoutMetrics.medium)

            // Dressing overlay covers the full screen so the dim doesn't
            // get cut off by the header / dress-button bars at top + bottom.
            // Hit testing is disabled so the dim never blocks the closet's
            // own buttons (X, archive). The shimmer text centers in the
            // ZStack which is effectively the screen centre — and because
            // header + dressButton take roughly equal vertical space, that
            // also corresponds to the visual middle between them.
            if isDressing {
                dressingOverlay
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        // Error banner is mounted as an overlay so it doesn't claim the
        // full ZStack frame (a `VStack { Spacer(); banner }` blocks taps
        // on every layer beneath it, including the header buttons).
        .overlay(alignment: .bottom) {
            if let dressError {
                errorBanner(message: dressError)
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isDressing)
        .animation(.easeInOut(duration: 0.25), value: dressError)
        .task { await loadLibrary() }
        .task {
            if avatar == nil {
                loadedAvatar = ClosetAvatarStorage.load(userId: userId)
            }
        }
        .onDisappear { dressTask?.cancel() }
        .fullScreenCover(isPresented: $showsRemixArchive) {
            RemixArchiveSheetView(onClose: { showsRemixArchive = false })
        }
    }

    private func selectedItemURL(for id: ClosetItem.ID?, in items: [ClosetItem]) -> URL? {
        guard let id, let item = items.first(where: { $0.id == id }) else { return nil }
        return URL(string: item.imageURL)
    }

    /// Returns the `dressedSelections` ID for the carousel that contains
    /// `item`, or nil. Used by carouselRow to decide which item should fade
    /// (the one currently centred AND matching what the avatar is wearing).
    private func appliedID(forCarouselContaining item: ClosetItem) -> ClosetItem.ID? {
        guard let dressed = dressedSelections else { return nil }
        if tops.contains(where: { $0.id == item.id }) { return dressed.top }
        if bottoms.contains(where: { $0.id == item.id }) { return dressed.bottom }
        if shoes.contains(where: { $0.id == item.id }) { return dressed.shoes }
        return nil
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                AppIcon(glyph: .xmark, size: 14, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("VIRTUAL CLOSET")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showsRemixArchive = true
            } label: {
                AppIcon(glyph: .stack, size: 16, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
    }

    // MARK: - Stage

    private var stage: some View {
        GeometryReader { geo in
            // Avatar scaled 1.5x relative to the natural aspect-fit size.
            // At 1.5x the frame width would exceed the screen for a square
            // avatar, so we use the full screen width and let scaledToFill
            // crop the empty side margins of the source image (the body
            // sits in a narrow central column with padding on either side,
            // so cropping ~30-40% of the image width is safe).
            let avatarAspect = avatarImageAspect ?? 0.5
            let availableHeight = geo.size.height
            let aspectFitHeight = min(availableHeight, geo.size.width / avatarAspect)
            let avatarHeight = min(aspectFitHeight * 1.5, availableHeight)
            let avatarWidth = geo.size.width
            let centerX = geo.size.width / 2
            // Push the avatar up toward the screen's vertical centre. The
            // stage sits between the header (~50pt) and dressButton (~70pt),
            // so the dressButton + bottom padding eats more vertical space
            // below the stage than the header eats above. Centering on
            // 0.42 of the stage compensates so the avatar visually anchors
            // around screen-mid rather than stage-mid. Clamped so the
            // avatar's top never goes negative — otherwise the avatar's
            // full-screen-width frame extends INTO the header area and
            // blocks taps on the X button.
            let centerY = max(geo.size.height * 0.42, avatarHeight / 2)
            let avatarTop = centerY - avatarHeight / 2

            ZStack {
                avatarView
                    .frame(width: avatarWidth, height: avatarHeight)
                    .clipped()
                    // Visual-only +25.4% (1.32 × 0.95). Layout frame stays
                    // the same size so row Ys (computed from avatarHeight)
                    // keep anchoring to the same body fractions; only the
                    // rendered avatar grows on screen.
                    .scaleEffect(1.254)
                    // Pulls the rendered avatar up so it sits in the
                    // visual centre of the stage despite the dressButton
                    // taking more vertical space below than the header
                    // takes above.
                    .offset(y: -40)
                    .position(x: centerX, y: centerY)
                    // Avatar is decorative — must not intercept taps,
                    // because the scaled visual extends past the stage
                    // bounds into the header area and would otherwise
                    // block the X / archive buttons.
                    .allowsHitTesting(false)

                // Draw order: bottoms (lowest), tops, shoes (highest).
                // Tops over bottoms preserves the coat-over-jeans visual
                // layering. Shoes on top so its ScrollView wins hit-tests
                // in the small overlap zone with bottoms (~0.81-0.96 of
                // the avatar) — without this, the bottoms row's full-
                // length hit area swallows touches meant for shoes.
                //
                // Anchor lines on the avatar (fractions of avatarHeight):
                //   shoulder ≈ 0.20, waist ≈ 0.50, floor ≈ 0.96.
                // rowY is the row's CENTRE, so we offset by ±frameHeight/2
                // depending on whether the row anchors at its top or bottom.
                let shoulderY = avatarTop + avatarHeight * 0.20
                let waistY = avatarTop + avatarHeight * 0.50
                let floorY = avatarTop + avatarHeight * 0.96

                let shoesItemH = avatarHeight * 0.15
                let bottomsItemH = avatarHeight * 0.51
                let topsItemH = avatarHeight * 0.42

                carouselRow(
                    items: bottoms,
                    selection: $bottomSelectionID,
                    itemHeight: bottomsItemH,
                    itemWidth: 195,
                    rowY: waistY + bottomsItemH / 2,
                    rowWidth: geo.size.width,
                    itemAlignment: .top
                )
                carouselRow(
                    items: tops,
                    selection: $topSelectionID,
                    itemHeight: topsItemH,
                    itemWidth: 195,
                    rowY: shoulderY + topsItemH / 2,
                    rowWidth: geo.size.width,
                    itemAlignment: .top
                )
                carouselRow(
                    items: shoes,
                    selection: $shoesSelectionID,
                    itemHeight: shoesItemH,
                    itemWidth: 165,
                    rowY: floorY - shoesItemH / 2,
                    rowWidth: geo.size.width,
                    itemAlignment: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()  // Prevents avatar / carousels from extending into the
                        // header (X button) or dressButton hit areas.
        }
    }

    /// Aspect (W/H) of the loaded avatar image. Used to lock the avatar's
    /// frame to the image's natural proportions so scaledToFit fills it
    /// exactly. Returns nil while the avatar is still loading.
    private var avatarImageAspect: CGFloat? {
        guard let img = displayAvatar, img.size.height > 0 else { return nil }
        return img.size.width / img.size.height
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatar = displayAvatar {
            Image(uiImage: avatar)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(AppPalette.textFaint.opacity(0.3))
                Text("AVATAR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(AppPalette.textFaint)
            }
        }
    }

    // MARK: - Carousel row

    /// Horizontal scrolling carousel. Snaps to the centred item; the
    /// `selection` binding tracks which item ID is currently centred (i.e.
    /// "applied" to the avatar). Items not centred peek past the avatar on
    /// either side.
    ///
    /// `itemAlignment` controls how items vertically align inside the row's
    /// frame: `.top` makes garments hang from the row's top edge (so a
    /// short crop and a long coat both start at the same shoulder line),
    /// `.bottom` makes items rest on the row's bottom edge (used for
    /// shoes so the soles always sit at the floor line). This is more
    /// robust than centring + per-product rowY tuning because it removes
    /// the dependency on each product image's internal padding.
    ///
    /// `expandFullBody` lets dresses/jumpsuits extend their frame height
    /// (up to 1.6× a regular slot, scaled by `lengthScale`); with `.top`
    /// alignment they hang from the same shoulder line as regular tops
    /// and naturally extend further down.
    private func carouselRow(
        items: [ClosetItem],
        selection: Binding<ClosetItem.ID?>,
        itemHeight: CGFloat,
        itemWidth: CGFloat,
        rowY: CGFloat,
        rowWidth: CGFloat,
        expandFullBody: Bool = false,
        itemAlignment: VerticalAlignment = .center
    ) -> some View {
        // Inset the scroll content so item 0 lands at the viewport centre
        // when the carousel is at scroll = 0. We use `.contentMargins`
        // instead of Color.clear children inside the LazyHStack because
        // those children would register as scroll-target snap points,
        // letting the carousel snap to "empty space" (viewport centre with
        // no item over the avatar). Margins live OUTSIDE the snap layout.
        let edgeInset = max(0, rowWidth / 2 - itemWidth / 2)
        let frameAlignment: Alignment = itemAlignment == .top ? .top
            : itemAlignment == .bottom ? .bottom
            : .center

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: itemAlignment, spacing: 0) {
                ForEach(items) { item in
                    let category = ProductCategory.inferring(from: item.name)
                    let isLong = expandFullBody && category == .fullBody
                    // Per-item length scale so a mini skirt renders shorter
                    // than jeans, a maxi dress longer than a mini, etc.
                    let lengthScale = ProductCategory.inferLengthScale(
                        name: item.name, category: category
                    )
                    // Frame height: regular items get itemHeight × scale;
                    // dresses occupy 1.6× the slot, also × scale.
                    let frameHeight = (isLong ? itemHeight * 1.6 : itemHeight) * lengthScale
                    // Fade the item out only when it's BOTH centred (so it's
                    // the one overlaying the avatar) AND it's what the avatar
                    // is currently dressed in. Swiping to a neighbour breaks
                    // either condition and the item snaps back to opacity 1.
                    let dressedID = appliedID(forCarouselContaining: item)
                    let isAppliedAndCentred = item.id == selection.wrappedValue
                        && item.id == dressedID
                    CachedClosetImage(
                        url: URL(string: item.imageURL),
                        contentMode: isLong ? .fill : .fit
                    )
                    // The frame's alignment controls where a scaledToFit
                    // image sits within its slot when there's whitespace —
                    // top-aligns hung garments to the slot's top edge,
                    // bottom-aligns shoes to the slot's floor edge. This
                    // is the missing piece that makes "anchor top/bottom"
                    // hold all the way down to the visible cloth.
                    .frame(width: itemWidth, height: frameHeight, alignment: frameAlignment)
                    .clipped()
                    .opacity(isAppliedAndCentred ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: isAppliedAndCentred)
                    .id(item.id)
                }
            }
            .frame(height: itemHeight, alignment: frameAlignment)
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, edgeInset, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: selection, anchor: .center)
        .scrollClipDisabled()
        .frame(width: rowWidth, height: itemHeight)
        .position(x: rowWidth / 2, y: rowY)
        .allowsHitTesting(!items.isEmpty)
    }

    // MARK: - Dress button

    @ViewBuilder
    private var dressButton: some View {
        let canAct = hasAnySelection && sourceAvatar != nil && !isDressing
        let inSaveMode = selectionMatchesDressed && dressedAvatar != nil
        let label: String = {
            if inSaveMode { return savedToRemixes ? "SAVED" : "SAVE OUTFIT" }
            return "DRESS AVATAR"
        }()
        let glyph: AppIconGlyph = inSaveMode
            ? (savedToRemixes ? .check : .bookmark)
            : .sparkles
        let glyphFilled = inSaveMode && !savedToRemixes  // bookmark filled when in SAVE state

        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if inSaveMode {
                saveDressedOutfit()
            } else {
                runDressing()
            }
        } label: {
            HStack(spacing: 8) {
                AppIcon(
                    glyph: glyph,
                    size: 14,
                    color: AppPalette.textPrimary,
                    filled: glyphFilled
                )
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            // Pill-shaped CTA with the standard app drop shadow.
            .appCapsule()
            .opacity(canAct ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!canAct || savedToRemixes)
        .animation(.easeInOut(duration: 0.2), value: inSaveMode)
        .animation(.easeInOut(duration: 0.2), value: savedToRemixes)
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, LayoutMetrics.small)
    }

    // MARK: - Dressing overlay

    private func errorBanner(message: String) -> some View {
        Button {
            dressError = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DRESS FAILED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(AppPalette.textFaint)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppPalette.textMuted)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppPalette.groupedBackground)
                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppPalette.textFaint.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var dressingOverlay: some View {
        // Full-screen dim + sparkles. Text centres in the ZStack — since
        // the closet's header and dress button take roughly equal vertical
        // space, the screen centre matches the visual middle between them.
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            GenerationStarField()
                .ignoresSafeArea()
                .allowsHitTesting(false)
            ShimmerText(
                text: "DRESSING YOU, SIT TIGHT",
                font: .system(size: 11, weight: .bold, design: .monospaced),
                tracking: 2
            )
        }
    }

    // MARK: - Dress / save actions

    private func runDressing() {
        guard let source = sourceAvatar else { return }
        let topURL = selectedItemURL(for: topSelectionID, in: tops)
        let bottomURL = selectedItemURL(for: bottomSelectionID, in: bottoms)
        let shoesURL = selectedItemURL(for: shoesSelectionID, in: shoes)
        let snapshotSelections = currentSelections

        dressTask?.cancel()
        dressError = nil
        dressStatusDetail = "Dressing your avatar"
        isDressing = true

        dressTask = Task {
            do {
                let result = try await FalDressAvatarService.shared.dress(
                    avatar: source,
                    topImageURL: topURL,
                    bottomImageURL: bottomURL,
                    shoesImageURL: shoesURL
                ) { progress in
                    await MainActor.run { dressStatusDetail = progress.detail }
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    dressedAvatar = result
                    dressedSelections = snapshotSelections
                    savedToRemixes = false
                    isDressing = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    dressError = error.localizedDescription
                    isDressing = false
                }
            }
        }
    }

    private func saveDressedOutfit() {
        guard let dressedAvatar else { return }
        do {
            _ = try RemixStorage.save(
                image: dressedAvatar,
                userId: userId,
                topItem: remixItem(for: topSelectionID, in: tops),
                bottomItem: remixItem(for: bottomSelectionID, in: bottoms),
                shoesItem: remixItem(for: shoesSelectionID, in: shoes)
            )
            savedToRemixes = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            dressError = error.localizedDescription
        }
    }

    private func remixItem(for id: ClosetItem.ID?, in items: [ClosetItem]) -> RemixItem? {
        guard let id, let item = items.first(where: { $0.id == id }) else { return nil }
        return RemixItem(id: item.id, name: item.name, imageURL: item.imageURL)
    }

    // MARK: - Closet item assembly

    /// Combine the user's standalone product library with any products
    /// attached to their saved outfits — a lot of users have products on
    /// older outfits that never landed in the library table, so this gives
    /// the closet the widest possible source of items.
    ///
    /// Deduped by both trimmed lowercase name AND image URL — outfit-attached
    /// products often appear across many outfits with subtle name variations
    /// (trailing whitespace, typos), and a name-only key let those slip
    /// through as duplicates of the same image.
    private var allItems: [ClosetItem] {
        var seenNames = Set<String>()
        var seenURLs = Set<String>()
        var items: [ClosetItem] = []

        func nameKey(_ s: String) -> String {
            // Aggressive normalisation so "white sweater", "White Sweater 2",
            // "white sweater (3)" all collapse to one key. Users frequently
            // re-upload the same product with slightly different names.
            let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = lower.replacingOccurrences(
                of: "\\s*\\(?\\s*\\d+\\s*\\)?\\s*$",
                with: "",
                options: .regularExpression
            )
            return stripped
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        func urlKey(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for libraryItem in library {
            let n = nameKey(libraryItem.name)
            let u = urlKey(libraryItem.imageURL)
            if !n.isEmpty && seenNames.contains(n) { continue }
            if !u.isEmpty && seenURLs.contains(u) { continue }
            if !n.isEmpty { seenNames.insert(n) }
            if !u.isEmpty { seenURLs.insert(u) }
            items.append(ClosetItem(
                id: libraryItem.id.uuidString,
                name: libraryItem.name,
                imageURL: libraryItem.imageURL
            ))
        }

        for outfit in store.outfits {
            for product in outfit.products ?? [] {
                guard let resolved = product.resolvedImageURL?.absoluteString else { continue }
                let n = nameKey(product.name)
                let u = urlKey(resolved)
                if !n.isEmpty && seenNames.contains(n) { continue }
                if !u.isEmpty && seenURLs.contains(u) { continue }
                if !n.isEmpty { seenNames.insert(n) }
                if !u.isEmpty { seenURLs.insert(u) }
                items.append(ClosetItem(
                    id: "outfit-\(product.id)-\(outfit.id)",
                    name: product.name,
                    imageURL: resolved
                ))
            }
        }
        return items
    }

    private var tops: [ClosetItem] {
        // Dresses (fullBody) are intentionally excluded from this row for
        // now — they'll get their own carousel in a later version. Only
        // pure tops appear here.
        let filtered = allItems.filter { ProductCategory.inferring(from: $0.name) == .top }
        // One-off cleanup: skip the first 4 entries (legacy duplicate "white
        // sweater" uploads with subtly different names that slip past our
        // dedupe). Replace with a proper "delete from closet" UI when we
        // build closet item management.
        return Array(filtered.dropFirst(4))
    }
    private var bottoms: [ClosetItem] {
        allItems.filter { ProductCategory.inferring(from: $0.name) == .bottom }
    }
    private var shoes: [ClosetItem] {
        allItems.filter { ProductCategory.inferring(from: $0.name) == .shoes }
    }

    // MARK: - Loading

    private func loadLibrary() async {
        do {
            let products = try await ProductLibraryService.fetchProducts(userId: userId)
            await MainActor.run {
                library = products
                isLoading = false
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                isLoading = false
            }
        }
    }
}

/// Lightweight unification of `ProductLibraryItem` and `Outfit.products` —
/// the closet only needs name + image URL, so we collapse both sources into
/// a single shape and dedupe by lowercase name.
struct ClosetItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let imageURL: String
}

/// Snapshot of the three carousel selection IDs. Used to compare current
/// selection against what produced the dressed avatar — when they match the
/// action button flips to "SAVE OUTFIT".
struct ClosetSelections: Equatable {
    let top: ClosetItem.ID?
    let bottom: ClosetItem.ID?
    let shoes: ClosetItem.ID?
}

/// In-memory image cache shared across closet carousels. AsyncImage re-fetches
/// every time a row recycles or the user re-enters the sheet, which makes
/// swiping feel janky on repeat viewings. Holding decoded UIImages in-process
/// keeps repeat displays instant.
@MainActor
private final class ClosetImageCache {
    static let shared = ClosetImageCache()
    private var cache: [URL: UIImage] = [:]
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    func cached(_ url: URL) -> UIImage? { cache[url] }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cache[url] { return hit }
        if let task = inflight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return UIImage(data: data)
            } catch {
                return nil
            }
        }
        inflight[url] = task
        let result = await task.value
        inflight.removeValue(forKey: url)
        if let result { cache[url] = result }
        return result
    }
}

private struct CachedClosetImage: View {
    let url: URL?
    var contentMode: ContentMode = .fit
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(AppPalette.textFaint)
            } else {
                ProgressView().tint(AppPalette.textFaint)
            }
        }
        .task(id: url) {
            guard let url else { failed = true; return }
            if let hit = ClosetImageCache.shared.cached(url) {
                image = hit
                return
            }
            if let loaded = await ClosetImageCache.shared.load(url) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}
