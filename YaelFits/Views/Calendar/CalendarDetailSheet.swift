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

    private var selectedOutfit: Outfit? {
        guard let detailOutfitId else { return nil }
        return store.outfitById[detailOutfitId]
    }

    private func syncDetailState(selectedId: String?) {
        guard store.currentView == .calendar else {
            dismissImmediately()
            return
        }

        if let selectedId, store.outfitById[selectedId] != nil {
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
    @State private var keyboardHeight: CGFloat = 0
    @State private var isExpanded = false
    @State private var editableDate: Date = Date()
    @State private var showDatePicker = false

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

                VStack(spacing: 0) {
                    header
                    heroStage(stageHeight: stageHeight)
                        .scaleEffect(isExpanded ? 0.90 : 1.0, anchor: .top)
                        .frame(height: isExpanded ? stageHeight * 0.90 : stageHeight)
                        .scaleEffect(keyboardHeight > 0 ? 0.78 : 1.0, anchor: .top)
                        .padding(.bottom, keyboardHeight > 0 ? -66 : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isExpanded)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: -keyboardHeight * 0.5)
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
                if isEditing {
                    calEditableProductRow
                } else if let products = outfit.products, !products.isEmpty {
                    productRow(products)
                } else {
                    emptyProductRow
                }

                if isEditing {
                    calEditableTagRow
                } else if let tags = outfit.tags, !tags.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            TagPill(tag: tag) {
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                                selectedLinkedTag = LinkedTagSelection(id: tag)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    calEmptyTagRow
                }
            }

            HStack(spacing: 8) {
                publishButton
                Spacer(minLength: 0)
                deleteButton
                likeButton
                calShareButton
                if isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isEditing { saveCalendarEdits() }
                            else { editableTags = outfit.tags ?? []; editableDate = outfit.parsedDate ?? Date() }
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
                    userId: userId
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

    private var calEmptyTagRow: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { editableTags = outfit.tags ?? []; isEditing = true }
        } label: {
            HStack(spacing: 6) {
                AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.textFaint)
                Text("Add a tag")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppPalette.textMuted)
            }
            .frame(height: 36)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .appCapsule(shadowRadius: 0, shadowY: 0)
        }
        .buttonStyle(SolidPressButtonStyle())
    }

    private var calEditableProductRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showAddProduct = true
                } label: {
                    AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.iconPrimary)
                        .frame(width: 36, height: 36)
                        .appCircle(shadowRadius: 0, shadowY: 0)
                }
                .buttonStyle(SolidPressButtonStyle())

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await openAutoDetect() }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingAutoDetect {
                            ProgressView().controlSize(.small).tint(AppPalette.iconPrimary)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                                .foregroundStyle(AppPalette.iconPrimary)
                        }
                        Text("Quick Add")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
                    // AI-action accent: soft purple halo (matches carousel).
                    .shadow(color: AppPalette.aiAccent.opacity(0.18), radius: 8, y: 0)
                }
                .buttonStyle(SolidPressButtonStyle())
                .disabled(isLoadingAutoDetect)

                ForEach(outfit.products ?? [], id: \.id) { product in
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 4) {
                            ProductThumbnail(product: product)
                            Text(product.displayName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(AppPalette.textMuted)
                                .lineLimit(1)
                                .frame(width: 64)
                        }
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
                }
            }
            .padding(.horizontal, LayoutMetrics.medium).padding(.vertical, 8)
        }
        .padding(.horizontal, -LayoutMetrics.medium)
    }

    private var calEditableTagRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation { showingTagInput.toggle() }
                    } label: {
                        AppIcon(glyph: .plusCircle, size: 14, color: AppPalette.iconPrimary)
                        .frame(width: 36, height: 36)
                        .appCircle(shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(SolidPressButtonStyle())

                    ForEach(editableTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(AppPalette.textSecondary)
                            Button {
                                editableTags.removeAll { $0 == tag }
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
                    }
                }
                .padding(.horizontal, LayoutMetrics.medium)
            }
            .padding(.horizontal, -LayoutMetrics.medium)

            if showingTagInput {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        TextField("", text: $newTagText, prompt:
                            Text("New tag…").foregroundColor(AppPalette.textSecondary)
                        )
                        .font(.system(size: 13))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { commitCalTag() }
                        if !newTagText.isEmpty {
                            Button("Add") { commitCalTag() }
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
                        .filter { $0.lowercased().hasPrefix(newTagText.lowercased()) && !editableTags.contains($0) }
                        .prefix(5)
                        .map { $0 }
                    if !suggestions.isEmpty && !newTagText.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(suggestions, id: \.self) { s in
                                Button {
                                    newTagText = s; commitCalTag()
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
        }
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

    private func commitCalTag() {
        let t = newTagText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !editableTags.contains(t) else { return }
        editableTags.append(t); newTagText = ""
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

    private var publishButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            togglePublish()
        } label: {
            if isTogglingPublish {
                ProgressView()
                    .tint(AppPalette.textMuted)
                    .frame(height: 36)
                    .padding(.horizontal, 12)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            } else {
                Text(isPublished == true ? "UNPUBLISH" : "PUBLISH")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(isPublished == true ? AppPalette.textMuted : AppPalette.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .appCapsule(shadowRadius: 0, shadowY: 0)
            }
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

    private func productRow(_ products: [Product]) -> some View {
        let visibleProducts = Array(products.prefix(4))

        return Group {
            if visibleProducts.count <= 3 {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(visibleProducts) { product in
                        productCell(product)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(visibleProducts) { product in
                            productCell(product)
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.medium)
                }
                .padding(.horizontal, -LayoutMetrics.medium)
            }
        }
    }

    private var emptyProductRow: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showAddProduct = true
        } label: {
            HStack { EmptyProductCard() }
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
