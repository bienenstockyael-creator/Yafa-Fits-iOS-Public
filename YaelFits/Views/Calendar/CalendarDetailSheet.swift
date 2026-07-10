import SwiftUI

struct CalendarDetailOverlayHost: View {
    @Environment(OutfitStore.self) private var store

    @State private var detailOutfitId: String?
    @State private var detailMounted = false
    @State private var detailVisible = false

    var body: some View {
        Group {
            if store.currentView == .calendar, detailMounted, let outfit = selectedOutfit {
                CalendarDetailSheet(
                    outfit: outfit,
                    isVisible: detailVisible,
                    useFahrenheit: store.useFahrenheit,
                    isLiked: store.likedIds.contains(outfit.id),
                    showsDeleteAction: store.isLocalOutfit(outfit),
                    onDismiss: {
                        store.selectedOutfitId = nil
                    },
                    onToggleLike: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                            store.toggleLike(outfit.id)
                        }
                    },
                    onDelete: {
                        store.selectedOutfitId = nil
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))
                            store.deleteOutfit(outfit)
                        }
                    }
                )
            }
        }
        .onAppear {
            syncDetailState(selectedId: store.currentView == .calendar ? store.selectedOutfitId : nil)
        }
        .onChange(of: store.selectedOutfitId) { _, selectedId in
            guard store.currentView == .calendar else { return }
            syncDetailState(selectedId: selectedId)
        }
        .onChange(of: store.currentView) { _, currentView in
            guard currentView == .calendar else {
                dismissImmediately()
                return
            }
            syncDetailState(selectedId: store.selectedOutfitId)
        }
    }

    /// Last successfully-resolved outfit. If a store mutation (save,
    /// product add, refresh) makes the id unresolvable for a moment,
    /// the card KEEPS RENDERING this copy instead of unmounting —
    /// unmounting a view while one of its sheets is presented strands
    /// the app in a dead modal state (screen frozen, only tab taps
    /// respond).
    @State private var cachedOutfit: Outfit?

    private var selectedOutfit: Outfit? {
        guard let detailOutfitId else { return nil }
        if let live = store.outfitById[detailOutfitId] {
            return live
        }
        return cachedOutfit?.id == detailOutfitId ? cachedOutfit : nil
    }

    private func syncDetailState(selectedId: String?) {
        guard store.currentView == .calendar else {
            dismissImmediately()
            return
        }

        if let selectedId, store.outfitById[selectedId] == nil,
           cachedOutfit?.id != selectedId {
            // Ghost selection: an id with no resolvable outfit renders
            // NO card, but a non-nil selection still disables the
            // calendar's scroll — an invisible "freeze" only a tab tap
            // cleared. DEBOUNCED self-heal: a store mutation can make
            // the id unresolvable for a tick; clearing instantly would
            // rip the card (and any presented sheet) out from under
            // the user.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if store.selectedOutfitId == selectedId,
                   store.outfitById[selectedId] == nil {
                    store.selectedOutfitId = nil
                }
            }
            return
        }

        if let selectedId,
           let outfit = store.outfitById[selectedId]
               ?? (cachedOutfit?.id == selectedId ? cachedOutfit : nil) {
            cachedOutfit = outfit
            detailOutfitId = selectedId
            detailMounted = true

            Task { @MainActor in
                await Task.yield()
                await Task.yield()
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) {
                    detailVisible = true
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.28)) {
            detailVisible = false
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(580))
            guard store.currentView == .calendar, store.selectedOutfitId == nil else { return }
            detailMounted = false
            detailOutfitId = nil
        }
    }

    private func dismissImmediately() {
        detailVisible = false
        detailMounted = false
        detailOutfitId = nil
    }
}

struct CalendarDetailSheet: View {
    let outfit: Outfit
    let isVisible: Bool
    let useFahrenheit: Bool
    let isLiked: Bool
    let showsDeleteAction: Bool
    let onDismiss: () -> Void
    let onToggleLike: () -> Void
    let onDelete: () -> Void
    @Environment(OutfitStore.self) private var store
    @State private var showDeleteConfirmation = false
    @State private var selectedLinkedProduct: Product?
    @State private var selectedLinkedTag: LinkedTagSelection?
    @State private var isPublished: Bool?
    @State private var isTogglingPublish = false
    @State private var showShareComposer = false
    @State private var showAddProduct = false
    @State private var autoDetectSource: QuickAddSource?
    @State private var isLoadingAutoDetect = false
    @State private var isEditing = false
    @State private var editableTags: [String] = []
    @State private var showingTagInput = false
    @State private var newTagText = ""
    /// View-mode inline tag input (distinct from the edit-session
    /// `showingTagInput` so the two flows can't cross wires).
    @State private var showingViewTagInput = false
    @FocusState private var calTagFieldFocused: Bool
    @State private var keyboardHeight: CGFloat = 0
    @State private var isExpanded = false
    @State private var editableDate: Date = Date()
    @State private var showDatePicker = false
    /// Snapshots captured on entering EDIT. Tag/product changes
    /// persist INSTANTLY (the inline model), so Cancel can't rely on
    /// pending state — it restores these instead. SAVE discards them.
    @State private var preEditTags: [String]?
    @State private var preEditProducts: [Product]?
    #if DEBUG
    /// TEMP freeze forensics — see header chip.
    @State private var dbgButtonTaps = 0
    /// Any tap landing ANYWHERE in the card subtree (simultaneous, so
    /// it never competes with the buttons).
    @State private var dbgCardTaps = 0
    #endif

    var body: some View {
        ZStack {
            Color.black.opacity(0.04)
                .ignoresSafeArea()
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .onTapGesture(perform: onDismiss)

            GeometryReader { geometry in
                let width = min(max(geometry.size.width - (LayoutMetrics.screenPadding * 2), 0), 600)
                let stageHeight: CGFloat = min(geometry.size.height * 0.51, 480)
                // Hero shrinks when the card's lower half grows, so
                // the card's TOTAL height stays inside the tab-bar-
                // safe zone (the safeAreaInset tab strip hit-tests
                // above this overlay and eats any control under it).
                // Edit mode reuses the SAME rows as view mode (they
                // just grow ×'s), so it needs no extra shrink —
                // entering EDIT moves nothing.
                let heroFactor: CGFloat = isExpanded ? 0.90 : 1.0

                VStack(spacing: 0) {
                    header
                    // NATIVE height, not a scaleEffect: scaling the
                    // stage visually while framing it shorter centered
                    // the un-scaled layout box in the frame, shoving
                    // the weather pill + outfit up OUT of the card at
                    // small factors. Passing the reduced height in
                    // lays everything out inside it correctly.
                    heroStage(stageHeight: stageHeight * heroFactor)
                        .scaleEffect(keyboardHeight > 0 ? 0.78 : 1.0, anchor: .top)
                        .padding(.bottom, keyboardHeight > 0 ? -66 : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
                        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isEditing)
                    footer
                }
                .padding(.horizontal, LayoutMetrics.medium)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.medium)
                .frame(width: width)  // height is automatic — card scales with content
                .background {
                    LightBlurView(style: .systemThinMaterialLight)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .fill(Color(white: 0.92).opacity(0.55))
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(AppPalette.cardBorder, lineWidth: 0.85)
                )
                .shadow(color: AppPalette.cardShadow.opacity(0.72), radius: 26, y: 12)
                #if DEBUG
                // TEMP freeze forensics: counts ANY tap that reaches
                // the card's subtree. Simultaneous -> never competes
                // with the real buttons. Strip once the freeze closes.
                .simultaneousGesture(TapGesture().onEnded { dbgCardTaps += 1 })
                #endif
                // Tab-bar clearance ONLY while expanded: the tab bar
                // lives in a `safeAreaInset`, which hit-tests ABOVE
                // this overlay — the tall expanded card's footer slid
                // under that strip and its buttons went dead (the
                // "freezes until I tap a tab" bug). The collapsed card
                // fits centered with room to spare, so it stays truly
                // viewport-centered; expanding lifts it just enough,
                // on the same spring as the expansion itself.
                .padding(.bottom, isExpanded ? 96 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: -keyboardHeight * 0.5)
                .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
                .scaleEffect(isVisible ? 1 : 0.985)
                .offset(y: isVisible ? 0 : 22)
                .opacity(isVisible ? 1 : 0)
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55), value: isVisible)
            }
        }
        .sheet(item: $selectedLinkedProduct) { product in
            LinkedProductOutfitsSheet(product: product, sourceOutfit: outfit)
                .roundedSheetBackground()
        }
        .sheet(item: $selectedLinkedTag) { selection in
            LinkedTagOutfitsSheet(tag: selection.tag, sourceOutfit: outfit)
                .roundedSheetBackground()
        }
        .task {
            let published = await OutfitService.isPublished(outfitId: outfit.id)
            await MainActor.run { isPublished = published }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            if let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    keyboardHeight = frame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                keyboardHeight = 0
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            #if DEBUG
            // TEMP freeze forensics: card-side state + a tap counter
            // (t increments in the SHOW INFO/LESS and EDIT/SAVE button
            // actions). If a "dead" button's tap still bumps t, the
            // touch is arriving and the state machine is stuck; if t
            // doesn't move, something is eating the touch. Strip once
            // the freeze is closed.
            Text("t\(dbgButtonTaps) c\(dbgCardTaps)"
                + " w\(TouchCountGestureRecognizer.totalTouchesBegan)"
                + " e\(isEditing ? 1 : 0) x\(isExpanded ? 1 : 0)"
                + " in\(showingViewTagInput ? 1 : 0) kb\(Int(keyboardHeight))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(3)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            #endif
            if isEditing {
                Button { showDatePicker.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(calEditableDateLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(AppPalette.textSecondary)
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppPalette.textSecondary)
                    }
                }
                .buttonStyle(SolidPressButtonStyle())
            } else {
                Text(outfit.numericDateLabel(useFahrenheit: useFahrenheit))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.textFaint)
            }

            Spacer()

            Button(action: onDismiss) {
                AppIcon(glyph: .xmark, size: 12, color: AppPalette.iconPrimary)
                    .frame(width: 32, height: 32)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(SolidPressButtonStyle())
        }
        .padding(.bottom, 6)
    }

    private func heroStage(stageHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            if let weather = outfit.weather, !weather.condition.isEmpty {
                WeatherPill(weather: weather, useFahrenheit: useFahrenheit)
            }

            Spacer(minLength: 0)

            RotatableOutfitImage(
                outfit: outfit,
                height: stageHeight - 58,
                draggable: true,
                eagerLoad: true,
                autoRotate: true
            )
            .frame(maxWidth: .infinity)
            .opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 10)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45), value: isVisible)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: stageHeight, alignment: .top)
        .padding(.top, 2)
    }

    private var calEditableDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = useFahrenheit ? "MM/dd/yy" : "dd/MM/yy"
        return formatter.string(from: editableDate)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                Spacer(minLength: 0)

                Button {
                    #if DEBUG
                    dbgButtonTaps += 1
                    #endif
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                        if isEditing { saveCalendarEdits(); isEditing = false }
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "SHOW LESS" : "SHOW INFO")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textFaint)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AppPalette.iconPrimary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .frame(height: 36)
                }
                .buttonStyle(SolidPressButtonStyle())
            }

            if isExpanded {
                // ONE row for both modes — entering EDIT must not
                // reflow anything: products stay exactly where they
                // are and simply grow their ×'s.
                if let products = outfit.products, !products.isEmpty {
                    productRow(products, showsRemove: isEditing)
                } else {
                    emptyProductRow
                }

                // ONE tag row for both modes (edit just shows the
                // ×'s persistently). The + is ALWAYS present: one tap
                // → inline input → return commits and saves instantly.
                calViewTagRow
            }

            HStack(spacing: 8) {
                publishButton
                Spacer(minLength: 0)
                deleteButton
                likeButton
                calShareButton
                if isExpanded {
                    if isEditing {
                        // Cancel restores the pre-EDIT snapshots —
                        // inline edits saved instantly during the
                        // session, so "cancel" = write them back.
                        Button {
                            #if DEBUG
                            dbgButtonTaps += 1
                            #endif
                            cancelCalendarEdits()
                        } label: {
                            Text("CANCEL")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(AppPalette.textFaint)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .appCapsule(shadowRadius: 0, shadowY: 0)
                        }
                        .buttonStyle(SolidPressButtonStyle())
                        .transition(.scale.combined(with: .opacity))
                    }
                    Button {
                        #if DEBUG
                        dbgButtonTaps += 1
                        #endif
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isEditing {
                                saveCalendarEdits()
                                preEditTags = nil
                                preEditProducts = nil
                            } else {
                                // Snapshot for Cancel — inline edits
                                // save instantly.
                                preEditTags = calCurrentTags
                                preEditProducts = store.outfitById[outfit.id]?.products ?? outfit.products ?? []
                                editableTags = outfit.tags ?? []
                                editableDate = outfit.parsedDate ?? Date()
                            }
                            isEditing.toggle()
                        }
                    } label: {
                        Text(isEditing ? "SAVE" : "EDIT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(isEditing ? AppPalette.textSecondary : AppPalette.textFaint)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .appCapsule(shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
        }
        .padding(.top, 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
        .frame(maxWidth: .infinity, alignment: .top)
        .alert("Delete outfit?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteOutfit(outfit)
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the outfit from your archive. Products and tags on other outfits are not affected.")
        }
        .fullScreenCover(isPresented: $showShareComposer) {
            ShareCardComposer(outfit: outfit).environment(store)
                .snapshotDragDismiss(onClose: { showShareComposer = false })
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showAddProduct) {
            if let userId = store.userId {
                AddProductSheet(userId: userId, outfitId: outfit.id) { product in
                    let p = Product(name: product.name, price: nil, image: product.imageURL,
                                    productId: product.id, tags: product.tags)
                    store.updateOutfit(outfit.id, caption: outfit.caption,
                                       products: (outfit.products ?? []) + [p])
                }
                .roundedSheetBackground()
            }
        }
        .sheet(item: $autoDetectSource) { source in
            if let userId = store.userId {
                AutoDetectProductsView(
                    sourceImage: source.image,
                    userId: userId,
                    onAddManually: {
                        // Same handoff as the carousel card: AutoDetect
                        // dismisses itself; defer the manual sheet one
                        // beat so SwiftUI doesn't present back-to-back.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            showAddProduct = true
                        }
                    }
                ) { newProduct in
                    let existing = store.outfitById[outfit.id]?.products ?? outfit.products ?? []
                    guard !existing.contains(where: { $0.name == newProduct.name }) else { return }
                    store.updateOutfit(
                        outfit.id,
                        caption: outfit.caption,
                        products: existing + [newProduct]
                    )
                }
                .roundedSheetBackground()
            }
        }
        .sheet(isPresented: $showDatePicker) {
            VStack(spacing: 16) {
                Text("CHANGE DATE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(AppPalette.textFaint)
                DatePicker("", selection: $editableDate, displayedComponents: .date)
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

    // MARK: - View-mode tag row (inline add, instant save)

    /// Tags the card CURRENTLY has — store copy first so instant
    /// commits echo back immediately.
    private var calCurrentTags: [String] {
        store.outfitById[outfit.id]?.tags ?? outfit.tags ?? []
    }

    /// The everyday tag row: the + is always present, tapping it opens
    /// the inline input right here (no edit mode), return commits AND
    /// saves. While the input is open the pills grow ×'s for one-tap
    /// removal; when the keyboard drops they're tappable tag links
    /// again. Mirrors the carousel card.
    private var calViewTagRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Centered while it fits (like the product row); once the
            // tags overflow, falls back to a leading-aligned scroll
            // with the + first — never clipped at the left edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { calViewTagRowContent }
                    .frame(maxWidth: .infinity, alignment: .center)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { calViewTagRowContent }
                        .padding(.horizontal, LayoutMetrics.medium)
                }
                .padding(.horizontal, -LayoutMetrics.medium)
            }

            if showingViewTagInput {
                calInlineTagInput
            }
        }
        .onChange(of: calTagFieldFocused) { _, focused in
            // Keyboard dropped (tap-out, Done) → leave the inline
            // micro-state; pills go back to tappable tag links.
            if !focused {
                withAnimation(.easeInOut(duration: 0.15)) { showingViewTagInput = false }
            }
        }
    }

    @ViewBuilder
    private var calViewTagRowContent: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) { showingViewTagInput = true }
            calTagFieldFocused = true
        } label: {
            AppIcon(glyph: .plusCircle, size: 12, color: AppPalette.iconPrimary)
                .frame(width: 30, height: 30)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())

        if calCurrentTags.isEmpty && !showingViewTagInput {
            Text("Add a tag")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(AppPalette.textFaint)
        }

        ForEach(calCurrentTags, id: \.self) { tag in
            if showingViewTagInput || isEditing {
                HStack(spacing: 4) {
                    Text(tag.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(AppPalette.textSecondary)
                    Button {
                        calRemoveTagInstantly(tag)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AppPalette.textFaint)
                    }
                    .buttonStyle(SolidPressButtonStyle())
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .appCapsule(shadowRadius: 0, shadowY: 0)
            } else {
                TagPill(tag: tag) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    selectedLinkedTag = LinkedTagSelection(id: tag)
                }
            }
        }
    }

    private var calInlineTagInput: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("", text: $newTagText, prompt:
                    Text("New tag…").foregroundColor(AppPalette.textSecondary)
                )
                .font(.system(size: 13))
                .foregroundStyle(AppPalette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($calTagFieldFocused)
                .onSubmit { calCommitInlineTag() }
                if !newTagText.isEmpty {
                    Button("Add") { calCommitInlineTag() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppPalette.textSecondary)
                }
            }
            .padding(LayoutMetrics.xSmall)
            .background(AppPalette.pageBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppPalette.cardBorder, lineWidth: 1))

            let suggestions = store.allOutfitTags
                .filter { $0.lowercased().hasPrefix(newTagText.lowercased()) && !calCurrentTags.contains($0) }
                .prefix(5)
                .map { $0 }
            if !suggestions.isEmpty && !newTagText.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { s in
                        Button {
                            newTagText = s
                            calCommitInlineTag()
                        } label: {
                            Text(s)
                                .font(.system(size: 13))
                                .foregroundStyle(AppPalette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, LayoutMetrics.xSmall)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(SolidPressButtonStyle())
                        if s != suggestions.last { Divider().opacity(0.5) }
                    }
                }
                .background(AppPalette.pageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: AppPalette.cardShadow, radius: 6, y: 3)
            }
        }
    }

    private func calCommitInlineTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Return on an empty field = done tagging.
            calTagFieldFocused = false
            withAnimation(.easeInOut(duration: 0.15)) { showingViewTagInput = false }
            return
        }
        newTagText = ""
        var tags = calCurrentTags
        guard !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        calPersistTagsInstantly(tags)
    }

    private func calRemoveTagInstantly(_ tag: String) {
        var tags = calCurrentTags
        tags.removeAll { $0 == tag }
        calPersistTagsInstantly(tags)
    }

    /// Inline adds save immediately — no pending state, no Save step.
    private func calPersistTagsInstantly(_ tags: [String]) {
        // Keep the edit session's copy in step so SAVE can't rewrite
        // stale tags over an instant change.
        if isEditing { editableTags = tags }
        store.updateOutfitTags(outfitId: outfit.id, tags: tags)
        Task { try? await ProductLibraryService.updateOutfitTags(outfitId: outfit.id, tags: tags) }
    }



    /// Cancel = "as it was when I tapped EDIT": inline tag/product
    /// changes persisted instantly, so the snapshots get written back.
    private func cancelCalendarEdits() {
        if let preTags = preEditTags, preTags != calCurrentTags {
            calPersistTagsInstantly(preTags)
        }
        let liveProducts = store.outfitById[outfit.id]?.products ?? outfit.products ?? []
        if let preProducts = preEditProducts, preProducts != liveProducts {
            store.updateOutfit(outfit.id, caption: outfit.caption, products: preProducts)
        }
        preEditTags = nil
        preEditProducts = nil
        showingTagInput = false
        showDatePicker = false
        withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
    }

    private func saveCalendarEdits() {
        showingTagInput = false
        showDatePicker = false
        let tags = editableTags
        let outfitId = outfit.id
        store.updateOutfitTags(outfitId: outfitId, tags: tags)
        Task { try? await ProductLibraryService.updateOutfitTags(outfitId: outfitId, tags: tags) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let newDateString = formatter.string(from: editableDate)
        if newDateString != outfit.date {
            store.updateOutfitDate(outfitId: outfitId, date: newDateString)
            Task { try? await OutfitService.updateOutfitDate(outfitId: outfitId, date: newDateString) }
        }
    }


    private func openAutoDetect() async {
        guard !isLoadingAutoDetect else { return }
        await MainActor.run { isLoadingAutoDetect = true }
        defer { Task { @MainActor in isLoadingAutoDetect = false } }

        guard let image = await AutoDetectProductsView.loadCoverFrame(for: outfit) else { return }
        await MainActor.run { autoDetectSource = QuickAddSource(image: image) }
    }

    private var likeButton: some View {
        Button(action: onToggleLike) {
            AppIcon(
                glyph: .heart,
                size: 14,
                color: AppPalette.iconPrimary,
                filled: isLiked
            )
                .frame(width: 36, height: 36)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var calShareButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            showShareComposer = true
        } label: {
            AppIcon(glyph: .share, size: 14, color: AppPalette.iconPrimary)
                .frame(width: 36, height: 36)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    /// Publish toggle — the same globe as the carousel's action row:
    /// filled solid-black circle + white globe when the fit is live,
    /// passive circle otherwise.
    private var publishButton: some View {
        let live = isPublished == true
        return Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            togglePublish()
        } label: {
            Group {
                if isTogglingPublish {
                    ProgressView()
                        .controlSize(.small)
                        .tint(live ? .white : AppPalette.textMuted)
                } else {
                    AppIcon(glyph: .globe, size: 14, color: live ? .white : AppPalette.iconPrimary)
                }
            }
            .frame(width: 36, height: 36)
            .if(live) {
                $0.background(Circle().fill(Color.black))
                    .shadow(color: AppPalette.cardShadow, radius: 10, y: 5)
            }
            .if(!live) { $0.appCircle(shadowRadius: 0, shadowY: 0) }
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(isTogglingPublish || isPublished == nil)
    }

    private func togglePublish() {
        let newValue = !(isPublished ?? false)
        isTogglingPublish = true
        isPublished = newValue
        Task {
            do {
                try await OutfitService.setPublished(newValue, outfitId: outfit.id)
            } catch {
                await MainActor.run { isPublished = !newValue }
            }
            await MainActor.run { isTogglingPublish = false }
        }
    }

    private var deleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            AppIcon(glyph: .trash, size: 14, color: AppPalette.iconPrimary)
                .frame(width: 36, height: 36)
                .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func productRow(_ products: [Product], showsRemove: Bool = false) -> some View {
        // Always leads with + (straight into Quick Add) — adding a
        // product is the everyday action, no edit-mode round trip.
        // Centered while it fits; overflow falls back to a leading
        // scroll with the + first, never clipped at the left edge.
        // `showsRemove` (edit mode) overlays ×'s on the SAME cells —
        // no reflow when EDIT toggles.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                calProductRowCells(products, showsRemove: showsRemove)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    calProductRowCells(products, showsRemove: showsRemove)
                }
                .padding(.horizontal, LayoutMetrics.medium)
            }
            .padding(.horizontal, -LayoutMetrics.medium)
        }
    }

    @ViewBuilder
    private func calProductRowCells(_ products: [Product], showsRemove: Bool) -> some View {
        calAddProductChip
        ForEach(products) { product in
            if showsRemove {
                ZStack(alignment: .topTrailing) {
                    productCell(product)
                    Button {
                        store.removeProduct(product, fromOutfitId: outfit.id)
                        Task { try? await ProductLibraryService.removeProductFromOutfit(outfitId: outfit.id, product: product) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .background(Color(red: 0.85, green: 0.25, blue: 0.25).clipShape(Circle()))
                    }
                    .buttonStyle(SolidPressButtonStyle())
                    .offset(x: 6, y: -6)
                }
            } else {
                productCell(product)
            }
        }
    }

    /// Same 48pt + circle as the edit row / carousel card — opens
    /// Quick Add (manual entry lives inside as "Add manually").
    private var calAddProductChip: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await openAutoDetect() }
        } label: {
            Group {
                if isLoadingAutoDetect {
                    ProgressView().controlSize(.small).tint(AppPalette.iconPrimary)
                } else {
                    AppIcon(glyph: .plusCircle, size: 16, color: AppPalette.iconPrimary)
                }
            }
            .frame(width: 48, height: 48)
            .appCircle(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
        .disabled(isLoadingAutoDetect)
        .frame(minHeight: 72)
    }

    private var emptyProductRow: some View {
        // Same behavior as the carousel card: tapping the empty
        // placeholder jumps straight into Quick Add (AutoDetect) —
        // one tap to tag a product; manual entry lives inside that
        // sheet as "Add manually".
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await openAutoDetect() }
        } label: {
            HStack { EmptyProductCard(size: 88, cornerRadius: 16, iconSize: 22) }
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private func productCell(_ product: Product) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            selectedLinkedProduct = product
        } label: {
            VStack(spacing: 6) {
                ProductThumbnail(product: product)

                Text(product.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 72)
            }
        }
        .buttonStyle(SolidPressButtonStyle())
    }


}
