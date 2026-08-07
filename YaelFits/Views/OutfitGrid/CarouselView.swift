import SwiftUI
import UIKit

struct CarouselView: View {
    let outfits: [Outfit]
    @Binding var currentIndex: Int
    let backdropOpacity: Double
    let showsChrome: Bool
    let showsCurrentLiveSlide: Bool
    let showsEntryOverlay: Bool
    /// True while the grid-level hero image is flying over the carousel
    /// (open/close transition). The hero draws ABOVE this whole view, so the
    /// diary note must hide during it — otherwise it reads as the note being
    /// "behind" the outfit, then popping in front when the hero fades.
    var heroTransitionActive: Bool = false
    let entryFrame: CarouselEntryFrame?
    let entryImage: UIImage?
    let onHeroTargetFrameChange: (CGRect) -> Void
    let onCurrentFrameChange: (Int) -> Void
    let onCurrentDisplayedFrameChange: (Int?) -> Void
    let onCurrentScrubBegan: () -> Void
    let onDeleteOutfit: (Outfit) -> Void
    let onDismiss: () -> Void
    /// Hides every owner-only affordance inside the detail card
    /// (publish, delete, edit, add-tag, add-product) so viewers on
    /// someone else's profile can still browse, scrub, like, and
    /// share without seeing actions they can't perform.
    var viewOnly: Bool = false
    /// Ids of archived fits whose 3D upgrade is currently rendering.
    /// Their slides show the sparkle field overlaid — everything else
    /// (detail card, product tagging, notes) behaves exactly like any
    /// saved 2D still, because that's what they are until the render
    /// lands and swaps the frames in place.
    var generatingOutfitIds: Set<String> = []

    @Environment(OutfitStore.self) private var store
    @State private var dragOffset: CGFloat = 0
    @State private var verticalNudge: CGFloat = 0
    @State private var verticalDismissOffset: CGFloat = 0
    @State private var isScrubbingCurrentOutfit = false
    @State private var isDismissing = false

    private static let cardInset: CGFloat = 12

    // Geometry of the bottom action band. The slide's `usableHeight`
    // subtracts `actionRowReserve` so the outfit can't grow down into
    // the buttons, and the band itself is pinned `actionRowBottomInset`
    // pt above the screen edge. The row's *height* is measured live
    // (`measuredActionRowHeight`) so the layout adapts to whichever
    // chrome is rendered (owner vs viewer) and to Dynamic Type.
    private static let actionRowBottomInset: CGFloat = 40
    /// Fallback height used until the live measurement arrives —
    /// picked so the first-frame slide size is visually close to
    /// what the measurement will produce on a modern phone.
    private static let actionRowHeightFallback: CGFloat = 88
    /// The slide is `aspectFit`, so the outfit naturally has empty
    /// pixels along its short edge — it tolerates dipping slightly
    /// into the action-row band without visual conflict.
    private static let actionRowOverlapTolerance: CGFloat = 18
    /// Distance from the carousel viewport's bottom up to the
    /// card's bottom edge when open. Held constant across owner /
    /// viewer surfaces so the card lands at the same screen Y in
    /// both modes — the chrome under it differs but is hidden
    /// while the card is open anyway.
    private static let cardBottomInset: CGFloat = 30

    /// Live-measured action-row VStack height. Falls back to
    /// `actionRowHeightFallback` until the first measurement.
    @State private var measuredActionRowHeight: CGFloat?

    /// Vertical space the slide must leave for the action row so
    /// the outfit doesn't visually crash into the chrome. Adapts
    /// to whichever chrome is actually rendered (owner vs viewer,
    /// Dynamic Type).
    private var actionRowReserve: CGFloat {
        let rowHeight = measuredActionRowHeight ?? Self.actionRowHeightFallback
        return Self.actionRowBottomInset + rowHeight - Self.actionRowOverlapTolerance
    }

    private static let slideTopInset: CGFloat = LayoutMetrics.touchTarget + LayoutMetrics.xxSmall
    private static let minSlideHeight: CGFloat = 320
    /// 0.66 × the 1.2 scale that used to be applied via `scaleEffect`.
    /// Baking the 1.2 into the layout frame (instead of the visual
    /// scale) means the hero target rect matches the rendered rect —
    /// the entry transition lands without a "pop".
    private static let slideHeightFactor: CGFloat = 0.58 * 1.2

    @State private var viewWidth: CGFloat = UIScreen.main.bounds.width
    @State private var slideHeight: CGFloat = 318
    @State private var cardExpandProgress: CGFloat = 0
    /// Drives the share-composer fullscreen cover. The trigger lives
    /// in the carousel's chrome (`shareCircleButton`); we mount the
    /// cover here so it survives the card's open/close lifecycle.
    @State private var showShareComposer = false
    /// Drives the comments sheet — only reachable on viewer
    /// surfaces (`viewOnly`), via the chrome's comment circle.
    @State private var showComments = false

    // Shared edit session: under-the-pill date/location row reads
    // from this, and so does `CarouselDetailCard`. Replaces the
    // previous binding-and-callback dance with a single
    // `@Observable` object.
    @State private var editCoordinator = CarouselEditCoordinator()
    @FocusState private var isLocationFieldFocused: Bool
    /// Convenience: `isEditing` read shortcut.
    private var isEditing: Bool { editCoordinator.isEditing }
    /// How much the slide shrinks at full card expansion (0.34 →
    /// scale lands at 0.66). Roughly 1.2× the prior 0.55, giving
    /// the outfit more presence above the open card.
    // 0.34 shrank the outfit to 66% on card-open, leaving a dead gap
    // between the fit's feet and the card's top edge — 0.22 keeps it
    // at 78%, closing most of that whitespace.
    private static let cardExpandSlideShrink: CGFloat = 0.22
    /// Upward translation applied to the slide stack at full
    /// expansion. Combined with the scale, the slide visibly moves
    /// up; smaller magnitude here brings the outfit down on the
    /// screen. Also pulls the arrows down (they're computed from
    /// the slide's resulting center).
    private static let slideExpandTranslation: CGFloat = -20
    /// Lifted-up control for the detail card's mount/unmount. The
    /// new bottom-action Info button toggles this; swipe-up opens
    /// it; swipe-down closes it (and a second swipe dismisses the
    /// carousel entirely).
    @State private var isCardVisible = false
    /// Confirmation alert for the new bottom-row Delete text button.
    /// Mirrors the (still-existing) confirmation inside the detail
    /// card so the user always gets a prompt before destructive
    /// action, regardless of which surface they tap from.
    @State private var showDeleteConfirmation = false
    /// Outfit pending the publish (caption/products) sheet. nil at rest.
    @State private var outfitToPublish: Outfit?
    /// Per-outfit optimistic published state, keyed by outfit id, so the
    /// globe toggle feels instant before `outfit.isPublic` catches up.
    @State private var publishedOverride: [String: Bool] = [:]
    /// Outfit pending the unpublish confirmation dialog. nil at rest.
    /// Unpublishing is destructive (pulls the fit from the feed) so it
    /// gets a confirm step, unlike publishing which has its own sheet.
    @State private var outfitToUnpublish: Outfit?
    /// Share/publish attempted on a fit whose 3D render is still in
    /// flight — the action waits behind an app-styled "still being
    /// worked on" confirmation. nil at rest.
    @State private var generatingConfirm: GeneratingConfirm?

    private enum GeneratingConfirm {
        case share(Outfit)
        case publish(Outfit)
        var key: String {
            switch self {
            case .share(let o): return "share-\(o.id)"
            case .publish(let o): return "publish-\(o.id)"
            }
        }
    }
    /// Outfit whose diary note is being written/edited. nil at rest;
    /// set by a long-press (or the ghost affordance) on the fit.
    @State private var outfitToEditNote: Outfit?
    /// Global frame of the current fit slide (captured from the hero
    /// preference). The note editor anchors to it so positioning is WYSIWYG.
    @State private var currentSlideFrame: CGRect = .zero
    /// Ghost-note education state (see `ghostNoteGate` / `GhostNoteHintView`).
    @State private var ghostNoteShownThisSession = false
    private static let ghostNoteCountKey = "diaryNoteHintShownCount"
    private static let ghostNoteCreatedKey = "diaryNoteCreatedOnce"
    /// Mirrors the chevron press inside the card and the new Info
    /// button outside it. Tracking it as a single source of truth
    /// keeps the spring animation consistent regardless of which
    /// surface triggered the open/close.
    private let cardSpring = Animation.spring(response: 0.4, dampingFraction: 0.78)

    private var slideWidth: CGFloat {
        viewWidth - (Self.cardInset * 2)
    }

    /// Slide height for a given viewport height. Instance method
    /// (not `static`) because `actionRowReserve` is measurement-
    /// backed and lives on `self`.
    private func slideHeight(forGeometryHeight geoHeight: CGFloat) -> CGFloat {
        let usable = geoHeight - Self.slideTopInset - actionRowReserve
        return max(Self.minSlideHeight, usable * Self.slideHeightFactor)
    }

    private let gap: CGFloat = LayoutMetrics.xSmall

    var body: some View {
        // Local `@Bindable` so sheet/picker bindings can be expressed
        // as `$editCoordinator.foo` — the same coordinator instance,
        // just projected as a `Binding`-able reference.
        @Bindable var editCoordinator = editCoordinator
        return ZStack {
            AppPalette.pageBackground
                .ignoresSafeArea()
                .opacity(backdropOpacity)
                .contentShape(Rectangle())
                .allowsHitTesting(backdropOpacity > 0.08)
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    // Tap-outside semantics: when the detail card is
                    // open, close it; otherwise dismiss the carousel
                    // back to the index. Swipe-down has the same
                    // two-stage behavior (see the carousel's main
                    // drag gesture).
                    if isCardVisible {
                        toggleCard()
                    } else {
                        onDismiss()
                    }
                }

            Color.black.opacity(0.1)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(backdropOpacity)

            GeometryReader { geo in
                let computedSlideHeight = slideHeight(forGeometryHeight: geo.size.height)
                ZStack(alignment: .bottom) {
                    VStack(spacing: LayoutMetrics.small) {
                        // Always reserve the weather pill's slot so
                        // the date/location label and the slide don't
                        // shift up when the outfit has no weather tag.
                        // The pill itself only renders when there's a
                        // condition; absent that, the slot stays empty
                        // but the same height.
                        ZStack {
                            if let outfit = currentOutfit,
                               let weather = outfit.weather,
                               !weather.condition.isEmpty {
                                WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
                                    .opacity(showsChrome && outfitToEditNote == nil ? 1 : 0)
                                    .allowsHitTesting(showsChrome)
                            }
                        }
                        .frame(height: 36)
                        // Push the weather pill slightly down from
                        // its anchored top, but stay strictly
                        // less than the VStack's `small` (16pt)
                        // spacing — anything ≥16 would visually
                        // overlap into the date/location label
                        // because `.offset` doesn't shift layout,
                        // only rendering. Returns to 0 as the
                        // card expands.
                        .offset(y: 3 * (1.0 - cardExpandProgress))

                        // Date · location centered under the weather
                        // pill. Stays put whether the card is open
                        // or closed — in edit mode it flips to
                        // editable inputs in place (`dateLocationLabel`
                        // switches between static text and the
                        // editable input pair via `isEditing`).
                        if let outfit = currentOutfit {
                            dateLocationLabel(for: outfit)
                                .opacity(showsChrome && outfitToEditNote == nil ? 1 : 0)
                                .allowsHitTesting(isEditing)
                        }

                        // Arrows used to sit inside this ZStack —
                        // moved out so they're centered to the
                        // viewport, not the slide. See `viewportNav`
                        // overlay below.
                        carouselSlides
                            .frame(height: slideHeight)
                            // Modest shrink (1.00 → 0.66) — keeps the
                            // outfit large enough that the expand
                            // animation reads as an upward translate
                            // rather than a "shrink in place." The
                            // 1.2× factor that used to live here is
                            // baked into slideHeight above, so the
                            // hero target rect matches the rendered
                            // visual without a scale "pop."
                            .scaleEffect(1.0 - (cardExpandProgress * Self.cardExpandSlideShrink), anchor: .top)
                            // Capture the slide's *rendered* center as
                            // an `Anchor<CGPoint>`. Resolving this via
                            // `proxy[anchor]` in the overlay below
                            // gives a coord-space-correct point that
                            // already accounts for this `.scaleEffect`
                            // and the parent VStack's `.offset` — so
                            // the nav-arrow placement needs zero
                            // manual scale/offset math. Previous
                            // attempts derived the slide center from
                            // measurements + hand-rolled scale math
                            // and kept landing in the wrong place;
                            // anchor preferences are the right tool
                            // because SwiftUI handles the transforms.
                            .anchorPreference(
                                key: SlideCenterAnchorKey.self,
                                value: .center
                            ) { $0 }
                        // Keyboard-driven scale removed: it compounded with
                        // the card-expand scale and stayed stuck after sheet
                        // dismissals (Quick Add). Default keyboard avoidance
                        // handles room for the caption field on its own.

                        Spacer(minLength: 0)
                    }
                    // Simple upward translation on card expand —
                    // combined with the scaleEffect above, the slide
                    // visibly moves up and shrinks. Both interpolate
                    // back to identity on collapse (offset → 0,
                    // scale → 1.0), so the slide returns to its
                    // original position.
                    .offset(y: slideExpandOffset())
                    .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isCardVisible)
                    .padding(.top, Self.slideTopInset)
                    // Nav arrows live in an overlay on the slide
                    // VStack (not on the outer ZStack) for two
                    // reasons:
                    //   1. z-order: the slide VStack is a sibling of
                    //      the card in the outer ZStack and rendered
                    //      *before* it — so this overlay sits above
                    //      the slide but *below* the card, which is
                    //      what we want (the open card slides on top
                    //      of the arrows, not the other way around).
                    //   2. Coord-space alignment: this overlay
                    //      inherits the same `.offset(slideExpandOffset)`
                    //      as the slide, so when `proxy[anchor]`
                    //      resolves the slide's rendered center the
                    //      result lands on the visible outfit
                    //      regardless of how far up the open card
                    //      has shifted everything.
                    // The VStack ends in a `Spacer(minLength: 0)` so
                    // it fills the available height — the overlay
                    // therefore spans the full viewport, which the
                    // GeometryReader inside needs for the
                    // viewport-center anchor at progress=0.
                    .overlayPreferenceValue(SlideCenterAnchorKey.self) { anchor in
                        GeometryReader { proxy in
                            let viewportCenterY = proxy.size.height / 2
                            let slideCenterY = anchor.map { proxy[$0].y } ?? viewportCenterY
                            let targetY = viewportCenterY + (slideCenterY - viewportCenterY) * cardExpandProgress
                            VStack {
                                Spacer(minLength: 0)
                                navButtons
                                Spacer(minLength: 0)
                            }
                            .offset(y: targetY - viewportCenterY)
                        }
                        .opacity(showsChrome && outfitToEditNote == nil ? 1 : 0)
                        .allowsHitTesting(showsChrome)
                    }

                    // Bottom action row — Save / Share / Info circles +
                    // optional Delete text. Pinned to the bottom of
                    // the ZStack at a fixed inset above the screen
                    // edge; the slide above reserves matching space
                    // (see `actionRowReserve`) so the outfit can't
                    // grow into the buttons.
                    if let outfit = currentOutfit, !isCardVisible {
                        bottomActionRow(outfit: outfit)
                            // Report the rendered height so the slide
                            // reserve and card-bottom inset both
                            // adapt to whatever the row actually
                            // measures — viewer chrome (4 circles)
                            // vs owner chrome (3 circles + Delete)
                            // differ, and so does Dynamic Type.
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ActionRowHeightKey.self,
                                        value: proxy.size.height
                                    )
                                }
                            )
                            .padding(.bottom, Self.actionRowBottomInset)
                            .opacity(showsChrome && outfitToEditNote == nil ? 1 : 0)
                            .allowsHitTesting(showsChrome)
                    }

                    if let outfit = currentOutfit {
                        CarouselDetailCard(
                            outfit: outfit,
                            isVisible: $isCardVisible,
                            editCoordinator: editCoordinator,
                            viewOnly: viewOnly
                        )
                            .padding(.horizontal, Self.cardInset)
                            // Pin the card's bottom edge to the bottom
                            // of the 3-circle action row (which is
                            // hidden while the card is open). The card
                            // sits flush atop those circles.
                            .padding(.bottom, Self.cardBottomInset)
                            .opacity(showsChrome && outfitToEditNote == nil ? 1 : 0)
                            .allowsHitTesting(showsChrome)
                    }
                }
                .onAppear {
                    viewWidth = geo.size.width
                    slideHeight = computedSlideHeight
                }
                .onChange(of: geo.size) { _, newSize in
                    viewWidth = newSize.width
                    slideHeight = slideHeight(forGeometryHeight: newSize.height)
                }
                // Single source of truth for the slide/arrow expand
                // animation. The carousel's Info button and outer
                // drag-down both flow through `toggleCard()`, but the
                // card's own chevron / drag-down only flip
                // `isCardVisible` (via `closeCard` inside the card),
                // so we mirror `cardExpandProgress` here to keep the
                // slide and arrows in sync no matter which close path
                // the user takes.
                .onChange(of: isCardVisible) { _, newValue in
                    withAnimation(cardSpring) {
                        cardExpandProgress = newValue ? 1 : 0
                    }
                }
                .onChange(of: editCoordinator.isEditing) { _, newValue in
                    // Surface edit state to the store so RootView
                    // can hide the X dismiss + temp toggle while
                    // the card is editing (it grows taller and the
                    // keyboard pushes it over that strip).
                    store.isCarouselCardEditing = newValue || (outfitToEditNote != nil)
                }
                .onChange(of: outfitToEditNote) { _, newValue in
                    // Note mode is a full takeover — hide RootView's X +
                    // temp toggle too (same flag the card editing uses).
                    store.isCarouselCardEditing = (newValue != nil) || editCoordinator.isEditing
                    // And stand down RootView's global tap-to-dismiss-keyboard
                    // handler, which was resigning the keyboard on every chip
                    // tap inside the editor.
                    store.isDiaryNoteEditing = (newValue != nil)
                    // Any editor open — ghost tap, long-press, publish-sheet
                    // row — retires the ghost hint forever: the user now
                    // knows the feature exists, which is all it teaches.
                    if newValue != nil {
                        UserDefaults.standard.set(true, forKey: Self.ghostNoteCreatedKey)
                    }
                }
                .onPreferenceChange(ActionRowHeightKey.self) { newHeight in
                    // Action row is conditionally mounted (hidden
                    // when the card is open) — it reports 0 then.
                    // Keep the last positive measurement so the
                    // slide reserve / card position don't snap as
                    // the user opens and closes the card.
                    if newHeight > 0 { measuredActionRowHeight = newHeight }
                }
                .onDisappear { store.isCarouselCardEditing = false }
            }
            .coordinateSpace(name: "carousel")
            // Extend through the bottom *container* safe area so the
            // viewport is the same on both surfaces — without this,
            // RootView's `.safeAreaInset(edge: .bottom)` (the tab
            // bar) shrinks size.height on the own-profile surface
            // while the fullScreenCover used by `UserProfileView`
            // leaves it taller, putting the slide and bottom
            // buttons at different screen Ys.
            //
            // Also ignore `.keyboard` so the entire carousel stays
            // anchored when the location or tag field gets focus —
            // the card grows tall and the keyboard would otherwise
            // shove the whole surface up by ~300pt, which felt
            // jarring (the slide jumped out the top).
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .offset(y: verticalDismissOffset)
            .opacity(isDismissing ? max(0.0, 1.0 - (verticalDismissOffset / 300.0)) : 1.0)
            .scaleEffect(isDismissing ? max(0.9, 1.0 - (verticalDismissOffset / 1500.0)) : 1.0, anchor: .top)
            .compositingGroup()
        }
        // Opt the entire carousel screen out of keyboard
        // avoidance. The inner `.ignoresSafeArea(.keyboard)` on the
        // GeometryReader wasn't enough — SwiftUI applies keyboard
        // avoidance at the outer scene level too, so the focused
        // location/tag field was still shoving the surface up.
        // Applying the modifier here as well stops that.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .fullScreenCover(isPresented: $showShareComposer) {
            if let outfit = currentOutfit {
                ShareCardComposer(outfit: outfit)
                    .environment(store)
                    .snapshotDragDismiss(onClose: { showShareComposer = false })
                    .presentationBackground(.clear)
            }
        }
        .sheet(item: $outfitToPublish) { outfit in
            PublishSheet(outfit: outfit, onAddNote: {
                // Close the sheet, then open the note editor once the
                // dismissal has visually cleared.
                outfitToPublish = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.easeOut(duration: 0.2)) { outfitToEditNote = outfit }
                }
            }) { caption, products in
                publishedOverride[outfit.id] = true
                // Persist locally too — the override dies with this view,
                // which made a just-published fit read as unpublished after
                // closing and reopening the carousel.
                store.setOutfitPublishedLocally(outfit.id, isPublic: true)
                store.updateOutfit(outfit.id, caption: caption, products: products)
            }
            .environment(store)
            .roundedSheetBackground()
        }
        // In-place note editor — an overlay ON the carousel (IG-style): the
        // chrome fades out and a dim drops over the live carousel; no sheet.
        .overlay {
            if let editing = outfitToEditNote {
                DiaryNoteEditOverlay(
                    slideFrame: currentSlideFrame,
                    initialText: editing.diaryNote ?? "",
                    initialStyle: DiaryNoteStyle.from(editing.noteStyle),
                    initialX: editing.noteX ?? 0.5,
                    // Unpositioned notes sit CENTERED on the fit — leaving
                    // typing mode keeps the text centered until the user
                    // deliberately drags/scales it.
                    initialY: editing.noteY ?? 0.5,
                    initialScale: editing.noteScale ?? 1,
                    initialRotation: editing.noteRotation ?? 0,
                    initialColorIndex: editing.noteColorIndex ?? 0,
                    onSave: { text, style, x, y, scale, rotation, colorIndex in
                        store.updateOutfitDiaryNote(
                            outfitId: editing.id,
                            note: text,
                            style: style,
                            shared: editing.noteShared ?? false,
                            x: x, y: y, scale: scale, rotation: rotation, colorIndex: colorIndex
                        )
                        // First real note retires the ghost-note hint forever.
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            UserDefaults.standard.set(true, forKey: Self.ghostNoteCreatedKey)
                        }
                        withAnimation(.easeOut(duration: 0.2)) { outfitToEditNote = nil }
                    },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.2)) { outfitToEditNote = nil }
                    }
                )
                // Fade the whole editor in/out. Gesture 1:1 tracking is
                // protected inside the editor itself (transaction strip is
                // scoped to the note while a gesture is live).
                .transition(.opacity)
            }
        }
        .overlay { unpublishConfirmOverlay }
        .overlay { generatingConfirmOverlay }
        .sheet(isPresented: $showComments) {
            if let outfit = currentOutfit {
                CommentsSheet(outfitId: outfit.id)
                    .environment(store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .roundedSheetBackground()
            }
        }
        .sheet(isPresented: $editCoordinator.showDatePicker) {
            VStack(spacing: 16) {
                Text("CHANGE DATE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textFaint)
                DatePicker("", selection: $editCoordinator.editableDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.black)
                    .colorScheme(.light)
            }
            .padding(LayoutMetrics.medium)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .roundedSheetBackground(AppPalette.pageBackground)
        }
    }

    private var carouselTempToggle: some View {
        HStack(spacing: 2) {
            carouselTempOption(label: "°F", isSelected: store.useFahrenheit) {
                withAnimation(.easeInOut(duration: 0.18)) { store.useFahrenheit = true }
            }
            carouselTempOption(label: "°C", isSelected: !store.useFahrenheit) {
                withAnimation(.easeInOut(duration: 0.18)) { store.useFahrenheit = false }
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(Capsule().fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98)))
        .overlay(Capsule().stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8))
    }

    private func carouselTempOption(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(isSelected ? AppPalette.textPrimary : AppPalette.textFaint)
                .frame(width: 40, height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var currentOutfit: Outfit? {
        outfits.indices.contains(currentIndex) ? outfits[currentIndex] : nil
    }

    // MARK: - New chrome (Phase 1 redesign)

    /// Centered date · location strip that sits under the weather
    /// pill. Always rendered (even when the card is open) — flips to
    /// editable inputs when the user enters edit mode, so the
    /// metadata anchor stays put and the card itself doesn't need
    /// to duplicate it.
    @ViewBuilder
    private func dateLocationLabel(for outfit: Outfit) -> some View {
        if isEditing {
            editableDateLocationRow()
        } else {
            staticDateLocationRow(for: outfit)
        }
    }

    private func staticDateLocationRow(for outfit: Outfit) -> some View {
        let date = outfit.numericDateLabel(useFahrenheit: store.useFahrenheit)
        let trimmedLocation = outfit.location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return HStack(spacing: 8) {
            Text(date)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(AppPalette.textFaint)
            if !trimmedLocation.isEmpty {
                Text("·")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppPalette.textFaint)
                Text(trimmedLocation)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textFaint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func editableDateLocationRow() -> some View {
        @Bindable var coordinator = editCoordinator
        return HStack(spacing: LayoutMetrics.small) {
            // Date field — sized to content, right-anchored in the
            // left half so as the date string grows the field
            // expands leftward.
            Button {
                coordinator.showDatePicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(editableDateLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppPalette.textSecondary)
                }
                .modifier(InputFieldChrome())
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(SolidPressButtonStyle())
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Location field — sized to content (via the placeholder
            // overlay so an empty TextField doesn't collapse to 0
            // width), left-anchored in the right half so as the
            // location string grows the field expands rightward.
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    // Only render the placeholder while empty —
                    // otherwise the ZStack would size to the longer
                    // of "ADD LOCATION" and the entered text, and
                    // short locations like "NEW YORK" would sit
                    // inside an oversized field.
                    if coordinator.editableLocation.isEmpty {
                        Text("ADD LOCATION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                    TextField("", text: $coordinator.editableLocation)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.textSecondary)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isLocationFieldFocused)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .onChange(of: coordinator.editableLocation) { _, newValue in
                            let cap = CarouselEditCoordinator.locationMaxLength
                            if newValue.count > cap {
                                coordinator.editableLocation = String(newValue.prefix(cap))
                            }
                        }
                }
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppPalette.textSecondary)
            }
            .modifier(InputFieldChrome())
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .onTapGesture {
                isLocationFieldFocused = true
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var editableDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = store.useFahrenheit ? "MM/dd/yy" : "dd/MM/yy"
        return formatter.string(from: editCoordinator.editableDate)
    }

    // Edit lifecycle (seed / commit / discard) lives in
    // `CarouselEditCoordinator`. The card's Edit/Save/Cancel
    // buttons call into it directly; this view just reads the
    // coordinator's working values to render the editable
    // date/location row.

    /// Save / Share / Info circle buttons plus a Delete text button.
    /// Replaces the old per-card publish/like/share/delete row and
    /// the floating INFO circle. Mounts at the bottom of the
    /// carousel viewport; hidden while the detail card is open.
    @ViewBuilder
    private func bottomActionRow(outfit: Outfit) -> some View {
        VStack(spacing: LayoutMetrics.xSmall) {
            HStack(spacing: LayoutMetrics.medium) {
                if viewOnly {
                    // Viewer chrome mirrors the public-feed card
                    // ordering: Like → Comment → Save (bookmark) →
                    // Cart (only when the outfit has products). No
                    // Share (the viewer isn't promoting someone
                    // else's outfit) and no t-shirt/info — the cart
                    // replaces it and reads as "shop the look".
                    likeCircleButton(outfit: outfit)
                    commentCircleButton
                    saveCircleButton(outfit: outfit)
                    if let products = outfit.products, !products.isEmpty {
                        cartCircleButton
                    }
                } else {
                    saveCircleButton(outfit: outfit)
                    publishCircleButton(outfit: outfit)
                    shareCircleButton(outfit: outfit)
                    infoCircleButton
                }
            }
            // Owner-only Delete sits below the circle row; rendered
            // as an invisible placeholder on viewer surfaces so the
            // 3 (or 4) circles always sit at the same vertical
            // position regardless of mode.
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showDeleteConfirmation = true
            } label: {
                Text("Delete")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .padding(.vertical, 6)
            }
            .buttonStyle(SolidPressButtonStyle())
            .opacity(viewOnly ? 0 : 1)
            .allowsHitTesting(!viewOnly)
            .accessibilityHidden(viewOnly)
        }
        .frame(maxWidth: .infinity)
        .alert("Delete outfit?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDeleteOutfit(outfit) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the outfit from your archive.")
        }
    }

    private func saveCircleButton(outfit: Outfit) -> some View {
        let isSaved = store.likedIds.contains(outfit.id)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            store.toggleLike(outfit.id)
        } label: {
            AppIcon(
                glyph: .bookmark,
                size: 16,
                color: AppPalette.iconPrimary,
                filled: isSaved
            )
            .frame(width: 48, height: 48)
            .appCircle()
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func shareCircleButton(outfit: Outfit) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isGenerating(outfit) {
                // 3D render in flight: confirm before sharing the
                // interim 2D version.
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    generatingConfirm = .share(outfit)
                }
            } else {
                showShareComposer = true
            }
        } label: {
            AppIcon(glyph: .share, size: 16, color: AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .appCircle()
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// Publish-to-feed toggle (owner only). A globe — the Friends/feed
    /// tab glyph — reads as "post this to the feed," and fills in when
    /// the outfit is live (same pattern as the save bookmark). Published
    /// state comes from `outfit.isPublic`, with a per-outfit optimistic
    /// override so the toggle feels instant. Tapping to publish opens
    /// the caption/products `PublishSheet`; tapping again unpublishes.
    private func publishCircleButton(outfit: Outfit) -> some View {
        let live = publishedOverride[outfit.id] ?? (outfit.isPublic == true)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if live {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    outfitToUnpublish = outfit
                }
            } else if isGenerating(outfit) {
                // 3D render in flight: confirm before publishing the
                // interim 2D version to the feed.
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    generatingConfirm = .publish(outfit)
                }
            } else {
                outfitToPublish = outfit
            }
        } label: {
            AppIcon(glyph: .globe, size: 16, color: live ? .white : AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .if(live) {
                    // Live: solid-black circle + white globe, mirroring
                    // the Save pill's active styling so a published fit
                    // is unmistakable in the row.
                    $0.background(Circle().fill(Color.black))
                        .shadow(color: AppPalette.cardShadow, radius: 12, y: 6)
                }
                .if(!live) { $0.appCircle() }
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// App-styled unpublish confirmation, replacing the system action
    /// sheet (which renders dark and clashes with the frosted-glass
    /// chrome). A soft scrim + frosted `appCard` matching the rest of
    /// the app, with a red-tinted destructive action.
    @ViewBuilder
    private var unpublishConfirmOverlay: some View {
        if let outfit = outfitToUnpublish {
            ZStack {
                // Dismissable scrim
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { dismissUnpublish() }
                    .transition(.opacity)

                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Text("Unpublish this fit?")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                        Text("It'll be removed from the feed.\nYou can publish it again anytime.")
                            .font(.system(size: 14, weight: .regular))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(AppPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        Button {
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            publishedOverride[outfit.id] = false
                            store.setOutfitPublishedLocally(outfit.id, isPublic: false)
                            Task { try? await OutfitService.setPublished(false, outfitId: outfit.id) }
                            dismissUnpublish()
                        } label: {
                            Text("Unpublish")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(
                                    Capsule().fill(Color(red: 0.90, green: 0.27, blue: 0.27))
                                )
                        }
                        .buttonStyle(SolidPressButtonStyle())

                        Button {
                            dismissUnpublish()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(AppPalette.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .appCapsule()
                        }
                        .buttonStyle(SolidPressButtonStyle())
                    }
                }
                .padding(22)
                .frame(maxWidth: 320)
                .appCard(cornerRadius: 28)
                .padding(.horizontal, 32)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: outfitToUnpublish?.id)
        }
    }

    private func dismissUnpublish() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            outfitToUnpublish = nil
        }
    }

    /// App-styled "fit still rendering" confirmation for share/publish
    /// — the exact scrim + frosted `appCard` recipe of
    /// `unpublishConfirmOverlay`, with a non-destructive black primary.
    @ViewBuilder
    private var generatingConfirmOverlay: some View {
        if let confirm = generatingConfirm {
            let isShare: Bool = {
                if case .share = confirm { return true }
                return false
            }()
            ZStack {
                // Dismissable scrim
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { dismissGeneratingConfirm() }
                    .transition(.opacity)

                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Text("This fit is still being worked on")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(AppPalette.textStrong)
                            .multilineTextAlignment(.center)
                        Text(isShare
                             ? "The 3D version is still rendering.\nShare the current version anyway?"
                             : "The 3D version is still rendering.\nPublish the current version anyway?")
                            .font(.system(size: 14, weight: .regular))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(AppPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        Button {
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            let action = confirm
                            dismissGeneratingConfirm()
                            switch action {
                            case .share:
                                showShareComposer = true
                            case .publish(let outfit):
                                outfitToPublish = outfit
                            }
                        } label: {
                            Text(isShare ? "Share anyway" : "Publish anyway")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Capsule().fill(Color.black))
                        }
                        .buttonStyle(SolidPressButtonStyle())

                        Button {
                            dismissGeneratingConfirm()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(AppPalette.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .appCapsule()
                        }
                        .buttonStyle(SolidPressButtonStyle())
                    }
                }
                .padding(22)
                .frame(maxWidth: 320)
                .appCard(cornerRadius: 28)
                .padding(.horizontal, 32)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: generatingConfirm?.key)
        }
    }

    private func dismissGeneratingConfirm() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            generatingConfirm = nil
        }
    }

    private var infoCircleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toggleCard()
        } label: {
            AppIcon(glyph: .tshirt, size: 16, color: AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .appCircle()
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    // MARK: - Viewer chrome (owner uses save/share/info above)

    /// Heart like — public engagement on someone else's outfit.
    /// Mirrors the public feed's like action so behavior is
    /// consistent across surfaces.
    private func likeCircleButton(outfit: Outfit) -> some View {
        let isLiked = store.likedIds.contains(outfit.id)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                store.toggleLike(outfit.id)
            }
        } label: {
            AppIcon(glyph: .heart, size: 16, color: AppPalette.iconPrimary, filled: isLiked)
                .frame(width: 48, height: 48)
                .appCircle()
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// Opens the comments sheet for the current outfit.
    private var commentCircleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showComments = true
        } label: {
            AppIcon(glyph: .comment, size: 16, color: AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .appCircle()
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// Cart — opens the detail card so the viewer can see the
    /// product cells (each with its own BUY pill). Replaces the
    /// owner's t-shirt/info button on viewer surfaces, and only
    /// renders when the outfit actually has products attached.
    private var cartCircleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toggleCard()
        } label: {
            AppIcon(glyph: .cart, size: 16, color: AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .appCircle()
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// Shared open/close so Info button, swipe-up, swipe-down, and
    /// the card's own collapse chevron all flow through one path.
    /// The card has only two states — visible (always fully shown)
    /// and hidden — so `cardExpandProgress` tracks `isCardVisible`
    /// 1:1.
    private func toggleCard() {
        withAnimation(cardSpring) {
            isCardVisible.toggle()
            cardExpandProgress = isCardVisible ? 1 : 0
        }
    }

    /// True when this fit's 3D upgrade is rendering (sparkle overlay).
    private func isGenerating(_ outfit: Outfit) -> Bool {
        generatingOutfitIds.contains(outfit.id)
    }


    /// Vertical offset applied to the slide stack (and the nav arrows)
    /// when the card opens, so the slide's bottom edge lands
    /// `slideToCardGap` above the card's top edge. `measuredCardHeight`
    /// is seeded with a sensible default and never zeroed, so this
    /// returns a stable target offset that scales linearly with
    /// `cardExpandProgress`. The spring animation on
    /// `cardExpandProgress` drives the slide and the arrows in lockstep.
    /// Vertical offset applied to the slide stack at full card
    /// expansion. Combined with the `cardExpandSlideShrink` scale,
    /// the slide shrinks and translates upward; on collapse both
    /// the scale and this offset interpolate back to identity.
    private func slideExpandOffset() -> CGFloat {
        Self.slideExpandTranslation * cardExpandProgress
    }

    private var carouselSlides: some View {
        GeometryReader { geometry in
            let center = geometry.size.width / 2
            let step = slideWidth + gap

            HStack(spacing: gap) {
                ForEach(Array(outfits.enumerated()), id: \.element.id) { index, outfit in
                    // Window the slides: building all N outfits at mount hogged
                    // the main thread for ~200-270ms right as the carousel
                    // opened (measured via the open HUD: pre-flight sleeps
                    // resuming ~8× late), which read as tap-then-nothing lag.
                    // Only slides within ±2 of the focus are real; the rest
                    // are size-matched clear placeholders so the HStack's
                    // layout math is identical. During a swipe only ±1 is
                    // ever visible, so the buffer materializes off-screen.
                    if abs(index - currentIndex) <= 2 {
                        carouselSlide(outfit: outfit, index: index)
                    } else {
                        Color.clear
                            .frame(width: slideWidth, height: slideHeight)
                    }
                }
            }
            .offset(
                x: center - slideWidth / 2 - CGFloat(currentIndex) * step + dragOffset,
                y: verticalNudge
            )
            .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.56), value: currentIndex)
            .if(showsChrome) { view in
                view.gesture(carouselSwipeGesture(step: step))
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            isScrubbingCurrentOutfit = false
            store.selectedOutfitId = currentOutfit?.id
            // Preload current + adjacent so frames are ready instantly
            for offset in [-1, 0, 1] {
                let idx = newIndex + offset
                guard outfits.indices.contains(idx) else { continue }
                let outfit = outfits[idx]
                Task {
                    if offset == 0 {
                        await FrameLoader.shared.preloadFullSequence(for: outfit)
                    } else {
                        _ = await FrameLoader.shared.frame(for: outfit, index: 0)
                    }
                }
            }
        }
        .onPreferenceChange(CarouselHeroTargetFramePreferenceKey.self) { frame in
            onHeroTargetFrameChange(frame)
            if !frame.isNull, frame.width > 0 { currentSlideFrame = frame }
        }
    }

    @ViewBuilder
    private func carouselSlide(outfit: Outfit, index: Int) -> some View {
        let distance = abs(index - currentIndex)
        let scale = max(0.82, 1.0 - Double(distance) * 0.16)
        let baseOpacity = max(0.38, 1.0 - Double(distance) * 0.34)
        let isCurrent = index == currentIndex
        let isNear = distance <= 1
        let slideOpacity: Double = if isCurrent {
            showsCurrentLiveSlide ? baseOpacity : 0
        } else {
            showsChrome ? baseOpacity : 0
        }
        let entryFrameIndex = entryFrame?.outfitId == outfit.id ? entryFrame?.frameIndex : nil
        let entryFrameImage = entryFrame?.outfitId == outfit.id ? entryImage : nil

        ZStack {
            RotatableOutfitImage(
                outfit: outfit,
                height: slideHeight,
                draggable: showsChrome && isCurrent,
                eagerLoad: isNear,
                // Deferred until the open transition lands (chrome fades in at
                // the very end of the hero sequence). Preloading on mount ran
                // a full-sequence decode storm DURING the hero flight — the
                // grid→carousel open's polling gates (target-frame stabilize +
                // displayed-frame wait) ran long against that contention, so
                // opens felt slow and snapped on timeout. Scrubbing is gated
                // on showsChrome anyway, so nothing is lost by waiting.
                preloadFullSequenceOnAppear: isCurrent && showsChrome,
                initialFrameIndex: entryFrameIndex,
                initialImage: entryFrameImage,
                syncFrameIndex: entryFrameIndex,
                syncImage: entryFrameImage,
                onHorizontalDragChange: showsChrome && isCurrent ? { isDragging in
                    if isDragging {
                        onCurrentScrubBegan()
                    }
                    isScrubbingCurrentOutfit = isDragging
                } : nil,
                onFrameChange: { frameIndex in
                    guard isCurrent else { return }
                    onCurrentFrameChange(frameIndex)
                },
                onDisplayedFrameChange: { frameIndex in
                    guard isCurrent else { return }
                    onCurrentDisplayedFrameChange(frameIndex)
                },
                // Drags that start in the slide's side margins (away
                // from the figure) fall through to the carousel's
                // page-swipe gesture instead of being captured by the
                // scrub recognizer — a forgiving swipe zone for users
                // who don't aim precisely at the outfit.
                horizontalDragInset: ScrubSwipe.edgeInset,
                // Distance + monotonicity hand-off. A scrub is small
                // back-and-forth motion that nets out below the
                // distance threshold OR has a large excursion range
                // relative to its net translation. A swipe is a long,
                // mostly one-direction drag where |net| ≈ range.
                onHorizontalDragRelease: isCurrent ? { release in
                    handleScrubRelease(release)
                } : nil
            )
            .opacity(slideOpacity)

            if isCurrent, let entryFrameImage {
                Image(uiImage: entryFrameImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
                    .opacity(showsEntryOverlay ? 1 : 0)
            }

            // Temp 2D self: sparkles over the still — same "magic
            // happening here" field as the archive placeholder cell.
            if isGenerating(outfit) {
                GenerationStarField(starSize: 200, interactive: false)
                    .allowsHitTesting(false)
                    .opacity(slideOpacity)
            }
        }
        .frame(width: slideWidth, height: slideHeight)
        .overlay {
            if isCurrent && outfitToEditNote == nil {
                diaryNoteOverlay(for: outfit)
                    .opacity(heroTransitionActive ? 0 : slideOpacity)
                    // Vanish instantly when a hero starts (close), fade in
                    // gently once it lands (open) — never visible under it.
                    .animation(heroTransitionActive ? nil : .easeOut(duration: 0.18),
                               value: heroTransitionActive)
            }
        }
        // Long-press the fit → enter note mode (add or edit). Simultaneous
        // so it coexists with the rotate scrub: a moving finger cancels the
        // press and drives rotation instead; a still hold opens the editor.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                guard isCurrent, !viewOnly else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                retireGhostNote()
                withAnimation(.easeOut(duration: 0.2)) { outfitToEditNote = outfit }
            }
        )
        .scaleEffect(scale, anchor: .bottom)
        .allowsHitTesting(showsChrome && isCurrent)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CarouselHeroTargetFramePreferenceKey.self,
                    value: isCurrent ? proxy.frame(in: .global) : .null
                )
            }
        }
    }

    /// The diary note (or the owner's "add a note" affordance) anchored
    /// at the bottom of the fit. Long-press the note to edit; the ghost
    /// affordance (empty state, owner only) taps straight in. Shown to
    /// viewers only when the owner has shared the note.
    @ViewBuilder
    private func diaryNoteOverlay(for outfit: Outfit) -> some View {
        if let note = outfit.diaryNote, !note.isEmpty {
            if !viewOnly || outfit.noteShared == true {
                // Display only (long-press the fit to edit), positioned at the
                // owner's chosen spot + scale within the slide frame.
                GeometryReader { geo in
                    // Only render once the frame is measured, so the note never
                    // flashes at (0,0) then jumps to its spot on appear.
                    if geo.size.width > 1 {
                        DiaryNoteView(
                            text: note,
                            style: DiaryNoteStyle.from(outfit.noteStyle),
                            color: DiaryInk.palette.indices.contains(outfit.noteColorIndex ?? 0)
                                ? DiaryInk.palette[outfit.noteColorIndex ?? 0] : .white,
                            size: 22,   // match the editor base size for WYSIWYG
                            wrapWidth: max(120, geo.size.width * 0.88)
                        )
                        // HARD width — under `.position()` the proposal is
                        // unspecified, so maxWidth never constrained and
                        // long notes never auto-wrapped (same fix as the
                        // editor). Matches the editor's wrap budget for
                        // WYSIWYG line breaks.
                        .frame(width: max(120, geo.size.width * 0.88))
                        .scaleEffect(CGFloat(outfit.noteScale ?? 1))
                        .rotationEffect(.radians(outfit.noteRotation ?? 0))
                        .position(
                            x: (outfit.noteX ?? 0.5) * geo.size.width,
                            y: (outfit.noteY ?? 0.5) * geo.size.height
                        )
                    }
                }
                .allowsHitTesting(false)
            }
        } else if !viewOnly {
            // Ghost-note education — no permanent button. The first few
            // times an owner opens a note-less fit, a faint note fades in
            // showing what a note looks like, where it lives, and the
            // gesture that makes one. Self-retiring: gone forever after
            // their first real note, or after 3 showings (max one per
            // carousel session). The Publish sheet's "Add a note" row is
            // the permanent discoverable fallback.
            //
            // Per-slide view with its OWN visibility state — a shared
            // @State died on every swipe because SwiftUI delivers the
            // previous slide's `onDisappear` late, switching the new
            // slide's ghost off right after it appeared.
            GhostNoteHintView(
                suppressed: isCardVisible,
                gate: ghostNoteGate,
                markShown: markGhostNoteShown,
                onTap: {
                    retireGhostNote()
                    withAnimation(.easeOut(duration: 0.2)) { outfitToEditNote = outfit }
                }
            )
        }
    }

    /// Whether the ghost may show right now. Retirement: the user has
    /// opened the note editor once (they know the feature) or the hint
    /// has shown 3 times; max one showing per carousel open.
    private func ghostNoteGate() -> Bool {
        let defaults = UserDefaults.standard

        // One-time reset for existing installs: the pre-1.1 ghost had
        // a shared-state bug that burned showings nobody ever saw, and
        // the retirement rule changed (editor interaction, not note
        // save) — start everyone fresh under the new rules.
        if !defaults.bool(forKey: "diaryNoteHintRulesV2") {
            defaults.set(true, forKey: "diaryNoteHintRulesV2")
            defaults.removeObject(forKey: Self.ghostNoteCreatedKey)
            defaults.removeObject(forKey: Self.ghostNoteCountKey)
        }

        guard !ghostNoteShownThisSession, !viewOnly else { return false }
        return !defaults.bool(forKey: Self.ghostNoteCreatedKey)
            && defaults.integer(forKey: Self.ghostNoteCountKey) < 3
    }

    /// The user interacted with the note editor — the ghost's lesson
    /// is learned; retire it permanently. Called synchronously from
    /// every editor entry point (ghost tap, long-press) so no showing
    /// can slip through between the gesture and the state change.
    private func retireGhostNote() {
        ghostNoteShownThisSession = true
        UserDefaults.standard.set(true, forKey: Self.ghostNoteCreatedKey)
    }

    private func markGhostNoteShown() {
        ghostNoteShownThisSession = true
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.ghostNoteCountKey) + 1,
                     forKey: Self.ghostNoteCountKey)
    }

    private func carouselSwipeGesture(step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isScrubbingCurrentOutfit else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let isMostlyVertical = abs(vertical) > abs(horizontal) * 2.0

                // Swipe up → open the detail card. Single-shot
                // gesture: fires the open-toggle on the first frame
                // that clearly looks upward, then ignores the rest
                // of the drag (no offset tracking — the card has
                // its own slide-in animation).
                if !isCardVisible && isMostlyVertical && vertical < -50 {
                    toggleCard()
                    return
                }

                // Only enter dismiss mode on a clear downward drag.
                // If the detail card is open, the first downward
                // drag collapses it instead of starting a dismiss —
                // the user has to swipe again to actually leave.
                if !isDismissing && vertical > 50 && isMostlyVertical {
                    if isCardVisible {
                        toggleCard()
                        return
                    }
                    isDismissing = true
                }

                if isDismissing {
                    verticalDismissOffset = max(0, vertical * 0.6)
                } else {
                    dragOffset = horizontal
                    verticalNudge = max(-18, min(18, vertical * 0.16))
                }
            }
            .onEnded { value in
                guard !isScrubbingCurrentOutfit else {
                    dragOffset = 0
                    verticalNudge = 0
                    return
                }

                if isDismissing {
                    let velocity = value.predictedEndTranslation.height
                    if verticalDismissOffset > 80 || velocity > 400 {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onDismiss()
                    }
                    withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)) {
                        verticalDismissOffset = 0
                        isDismissing = false
                    }
                    return
                }

                let threshold = max(48, step * 0.18)
                var changed = false

                if value.translation.width < -threshold, currentIndex < outfits.count - 1 {
                    currentIndex += 1
                    changed = true
                } else if value.translation.width > threshold, currentIndex > 0 {
                    currentIndex -= 1
                    changed = true
                }

                if changed {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                }

                withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)) {
                    dragOffset = 0
                    verticalNudge = 0
                }
            }
    }

    private var navButtons: some View {
        return HStack {
            navButton(icon: .chevronLeft, disabled: currentIndex <= 0) {
                currentIndex -= 1
            }
            Spacer()
            navButton(icon: .chevronRight, disabled: currentIndex >= outfits.count - 1) {
                currentIndex += 1
            }
        }
        .padding(.horizontal, Self.cardInset)
    }

    /// Tuning constants for the 3D-scrub → page-swipe hand-off.
    /// Adjust here rather than at the call sites.
    private enum ScrubSwipe {
        /// Side-margin width on each slide where a touch bypasses the
        /// scrub recognizer entirely and falls through to the page
        /// gesture — gives users a forgiving swipe zone that doesn't
        /// require precise aim on the figure.
        static let edgeInset: CGFloat = 60
        /// Fraction of slide width the net drag must cover before
        /// it's even considered a swipe candidate.
        static let distanceFractionOfSlide: CGFloat = 0.35
        /// Absolute floor for the distance threshold so very narrow
        /// slides still demand a deliberate drag.
        static let distanceFloor: CGFloat = 130
        /// |net| / excursionRange must be at least this. Purely
        /// one-direction drag = 1.0; any meaningful reversal drops
        /// the ratio below this floor, classifying the drag as a
        /// scrub instead of a swipe.
        static let monotonicityFloor: CGFloat = 0.80
        /// Page-swipe animation, matching the carousel's existing
        /// page-change curve.
        static let pageChangeAnimation = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)
    }

    /// Hand-off from the 3D scrub gesture to the carousel's page
    /// swipe. Requires BOTH a large absolute translation AND that the
    /// drag was mostly one-directional — a back-and-forth scrub that
    /// happens to net out past the distance threshold is filtered out
    /// by the monotonicity check, so users dialing in a rotation
    /// angle don't accidentally flip outfits.
    private func handleScrubRelease(_ release: HorizontalPanRelease) {
        let distanceThreshold = max(ScrubSwipe.distanceFloor, slideWidth * ScrubSwipe.distanceFractionOfSlide)
        guard abs(release.totalTranslation) > distanceThreshold else { return }
        guard release.monotonicityRatio >= ScrubSwipe.monotonicityFloor else { return }

        let direction = release.totalTranslation < 0 ? 1 : -1
        let proposedIndex = currentIndex + direction
        guard outfits.indices.contains(proposedIndex) else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(ScrubSwipe.pageChangeAnimation) {
            currentIndex = proposedIndex
        }
    }

    private func navButton(icon: AppIconGlyph, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.56)) {
                action()
            }
        } label: {
            AppIcon(glyph: icon, size: 16, color: AppPalette.iconPrimary)
                .frame(width: LayoutMetrics.touchTarget, height: LayoutMetrics.touchTarget)
                .appCircle(shadowRadius: 10, shadowY: 5)
                // Generous invisible hit-area around the 44pt visible
                // circle so the arrows are forgiving to tap even on
                // smaller phones; the visible button stays the same
                // size.
                .padding(20)
                .contentShape(Rectangle())
        }
        .buttonStyle(SolidPressButtonStyle())
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }
}

/// Anchor at the carousel slide's *rendered* center (post
/// `.scaleEffect`, post parent `.offset`). The nav-arrow overlay
/// resolves this via `proxy[anchor]` to land the arrows on the
/// outfit's visual center without any manual scale/offset math —
/// SwiftUI handles the cumulative transforms during anchor
/// resolution.
private struct SlideCenterAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        if let next = nextValue() { value = next }
    }
}

/// Reports the bottom action row's rendered height. Drives the
/// slide's `actionRowReserve` and the card's `cardBottomInset`
/// so both adapt to whichever chrome is currently rendered
/// (owner has 3 circles + Delete; viewer has up to 4 circles).
private struct ActionRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CarouselHeroTargetFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

/// Form-input chrome used by the editable date Button and the
/// editable location TextField inside the carousel's under-the-
/// pill row. Mirrors the white-fill + soft border treatment used
/// by the tag-input box inside `CarouselDetailCard` so all three
/// editable surfaces read as the same control type.
private struct InputFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppPalette.pageBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppPalette.cardBorder, lineWidth: 1)
            )
    }
}


/// Single source of truth for the grid→carousel hero open choreography.
/// The archive grid (`OutfitGridView`) and the user-profile sheet
/// (`UserProfileSheet`) each drive their own copy of the open/close
/// sequence; the timings and async primitives live HERE so a tuning change
/// can't silently drift between the two again — it did: durations, the
/// frame-stabilization fix, and the chrome-overlap order all diverged
/// before this was extracted.
enum CarouselHeroChoreography {
    static let heroFlightDuration: Double = 0.26
    static let revealFadeDuration: Double = 0.12
    static let backdropFadeInDuration: Double = 0.22
    static let chromeFadeInDuration: Double = 0.28
    static var heroFlightAnimation: Animation {
        .timingCurve(0.22, 0.84, 0.18, 1, duration: heroFlightDuration)
    }

    /// Polls `read()` every ~16ms until it returns the same non-null rect
    /// across two consecutive samples within the landing tolerance. The
    /// slide reports transient frames mid-initial-layout; flying the hero
    /// toward one of those makes the landing snap.
    @MainActor
    static func waitForStableFrame(fallback: CGRect, read: () -> CGRect) async -> CGRect {
        var lastFrame: CGRect?
        for _ in 0 ..< 30 {
            let frame = read()
            if !frame.isNull, frame.width > 0, frame.height > 0 {
                if let last = lastFrame, rectsMatch(last, frame) { return frame }
                lastFrame = frame
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return lastFrame ?? fallback
    }

    /// Polls every ~16ms until `check()` passes; false on timeout (~380ms).
    @MainActor
    static func waitUntil(_ check: () -> Bool) async -> Bool {
        for _ in 0 ..< 24 {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return false
    }

    /// True when two rects agree within the landing tolerance (0.5pt).
    /// Used both by the stabilization wait and by the post-flight landing
    /// correction ("did the slide settle away from where the hero flew?").
    static func rectsMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

/// Per-slide ghost-note hint with its OWN visibility state. One
/// instance mounts inside each note-less slide's overlay; unmounting
/// (swipe away, long-press into the editor) cancels its task and
/// takes its state with it. A CarouselView-shared @State was killed
/// on every swipe by the previous slide's late `onDisappear`.
///
/// Styled as the classic "add a note" app pill (pencil + capsule +
/// glow) and tappable straight into the editor — it just fades in and
/// out on the ghost's transient schedule instead of living there
/// permanently.
private struct GhostNoteHintView: View {
    /// True while the detail card covers the slide — hides the ghost
    /// without cancelling its run.
    let suppressed: Bool
    /// Evaluates the show conditions (session cap, retirement) at
    /// mount time.
    let gate: () -> Bool
    /// Marks the session flag + increments the lifetime counter.
    let markShown: () -> Void
    /// Tap → open the note editor for this fit.
    let onTap: () -> Void

    @State private var visible = false

    var body: some View {
        ZStack {
            if visible && !suppressed {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onTap()
                } label: {
                    HStack(spacing: LayoutMetrics.xxSmall) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 12, weight: .semibold))
                        Text("long press to add a note")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(AppPalette.textSecondary)
                    .padding(.horizontal, LayoutMetrics.xSmall)
                    .padding(.vertical, 7)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
                    .shadow(color: AppPalette.uploadGlow.opacity(0.3), radius: 12, y: 0)
                }
                .buttonStyle(SolidPressButtonStyle())
                .transition(.opacity)
            }
        }
        // Centered on the fit — it's an instruction about the gesture
        // you perform right here.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .task {
            guard gate() else { return }
            markShown()
            withAnimation(.easeIn(duration: 0.5)) { visible = true }
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { visible = false }
        }
    }
}
