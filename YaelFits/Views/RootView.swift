import SwiftUI
import Lottie

struct RootView: View {
    @Environment(OutfitStore.self) private var store

    private let headerContentInset: CGFloat = 0

    @State private var loaderMounted = true
    @State private var loaderVisible = true
    @State private var loaderDismissTask: Task<Void, Never>?
    @State private var showsFavoritesSheet = false
    @State private var feedHasAppeared = false
    // In-app notification banner
    @State private var showReviewBanner = false
    @State private var bannerDismissTask: Task<Void, Never>?

    // Hero transition state
    @State private var heroTransitioning = false
    @State private var heroOutfit: Outfit?
    @State private var heroImage: UIImage?
    @State private var heroFrame: CGRect = .zero
    @State private var heroOpacity: Double = 0
    @State private var heroFrameIndex: Int = 0
    @State private var viewTransitionTask: Task<Void, Never>?

    var body: some View {
        @Bindable var store = store

        ZStack(alignment: .top) {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                switch store.currentView {
                case .list, .calendar:
                    ZStack {
                        OutfitGridView()
                            .opacity(listViewOpacity)
                            .blur(radius: listViewBlur)
                            .allowsHitTesting(store.currentView == .list && !heroTransitioning)

                        CalendarMonthView()
                            .opacity(calendarViewOpacity)
                            .blur(radius: calendarViewBlur)
                            .allowsHitTesting(store.currentView == .calendar && !heroTransitioning)
                    }
                case .upload:
                    UploadPipelineView()
                case .profile:
                    ProfileView()
                default:
                    EmptyView()
                }

                // Feed stays mounted so scroll position is preserved across tab switches
                if store.currentView == .feed || feedHasAppeared {
                    PublicFeedListView()
                        .opacity(store.currentView == .feed ? 1 : 0)
                        .allowsHitTesting(store.currentView == .feed)
                        .frame(maxWidth: store.currentView == .feed ? .infinity : 0,
                               maxHeight: store.currentView == .feed ? .infinity : 0)
                        .onAppear { feedHasAppeared = true }
                }
            }
            .padding(.top, headerContentInset)

            if store.currentView != .feed {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                }
                .zIndex(90)
            }

            CalendarDetailOverlayHost()
                .zIndex(140)

            if let heroOutfit, heroTransitioning {
                viewTransitionHero(outfit: heroOutfit)
                    .zIndex(200)
            }

            if showsFloatingButtons {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        Spacer()
                        floatingFavoritesButton
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, LayoutMetrics.screenPadding)
                }
                .zIndex(65)
            }

            VStack {
                Spacer()
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)
            .zIndex(60)

            if loaderMounted {
                loadingOverlay
                    .zIndex(999)
            }

            // In-app review notification banner
            if showReviewBanner {
                VStack {
                    reviewBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .zIndex(500)
            }
        }
        .safeAreaInset(edge: .bottom) {
            tabBar
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onAppear {
            store.restorePersistedPendingReviewIfNeeded()
            syncLoadingOverlay(isLoading: store.isLoading)
            Task {
                await PushNotificationCoordinator.shared.requestAuthorization()
            }
        }
        .onChange(of: store.isLoading) { _, isLoading in
            syncLoadingOverlay(isLoading: isLoading)
        }
        .onChange(of: store.generationReadyForReview) { _, ready in
            guard ready else { return }
            store.generationReadyForReview = false
            if store.currentView != .upload {
                presentReviewBanner()
            }
        }
        .onDisappear {
            loaderDismissTask?.cancel()
            viewTransitionTask?.cancel()
            bannerDismissTask?.cancel()
        }
        .sheet(isPresented: $showsFavoritesSheet) {
            FavoritesSheetView()
                .environment(store)
        }
    }

    private var showsFloatingButtons: Bool {
        !store.isLoading
            && store.selectedOutfitId == nil
            && (store.currentView == .list || store.currentView == .calendar)
    }

    private var topBar: some View {
        HStack {
            logoView
            Spacer()
            HStack(spacing: 8) {
                if store.currentView == .list || store.currentView == .calendar {
                    if store.isCarouselOpen {
                        tempToggle
                    } else {
                        viewModeToggle
                    }
                } else if store.currentView == .profile {
                    tempToggle
                }
            }
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, LayoutMetrics.xSmall)
        .contentShape(Rectangle())
    }

    private var isCalendarActive: Bool {
        store.currentView == .calendar
    }

    // Cinematic crossfade: source blurs out, target blurs in
    private var listViewOpacity: Double {
        switch store.viewTransitionPhase {
        case .idle: return store.currentView == .list ? 1 : 0
        case .sourceOut: return store.currentView == .list ? 0 : 0  // source fading out, target not yet in
        case .targetIn: return store.currentView == .list ? 1 : 0   // target fading in
        }
    }

    private var listViewBlur: CGFloat {
        switch store.viewTransitionPhase {
        case .idle: return 0
        case .sourceOut: return store.currentView == .list ? 8 : 0
        case .targetIn: return store.currentView == .list ? 0 : 0
        }
    }

    private var calendarViewOpacity: Double {
        switch store.viewTransitionPhase {
        case .idle: return store.currentView == .calendar ? 1 : 0
        case .sourceOut: return store.currentView == .calendar ? 0 : 0
        case .targetIn: return store.currentView == .calendar ? 1 : 0
        }
    }

    private var calendarViewBlur: CGFloat {
        switch store.viewTransitionPhase {
        case .idle: return 0
        case .sourceOut: return store.currentView == .calendar ? 8 : 0
        case .targetIn: return store.currentView == .calendar ? 0 : 0
        }
    }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            viewModeOption(glyph: .grid, isSelected: !isCalendarActive) {
                guard isCalendarActive else { return }
                performViewTransition()
            }
            viewModeOption(glyph: .calendar, isSelected: isCalendarActive) {
                guard !isCalendarActive else { return }
                performViewTransition()
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98))
        )
        .overlay(
            Capsule()
                .stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8)
        )
        .padding(8)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: isCalendarActive)
    }

    // MARK: - Hero View Transition

    private func performViewTransition() {
        viewTransitionTask?.cancel()

        let goingToCalendar = !isCalendarActive
        let anchorId = store.centeredListOutfitId ?? store.sortedOutfits.first?.id

        // Find anchor outfit and its source frame
        let sourceFrames = goingToCalendar ? store.listOutfitFrames : store.calendarOutfitFrames
        guard let anchorId,
              let outfit = store.outfitById[anchorId]
        else {
            // No anchor — just switch view instantly
            store.selectedOutfitId = nil
            if goingToCalendar {
                store.pendingCalendarScrollOutfitId = anchorId
            }
            store.currentView = goingToCalendar ? .calendar : .list
            return
        }

        let sourceFrame = sourceFrames[anchorId]
        let frameIndex = store.listOutfitFrameIndices[anchorId] ?? 0

        viewTransitionTask = Task { @MainActor in
            // Step 1: Load hero image, hide anchor outfit
            heroOutfit = outfit
            heroFrameIndex = frameIndex
            heroImage = await FrameLoader.shared.frame(for: outfit, index: frameIndex)
            guard !Task.isCancelled else { return }

            let screenBounds = UIScreen.main.bounds
            let fallbackFrame = CGRect(
                x: screenBounds.midX - 50,
                y: screenBounds.midY - 85,
                width: 100,
                height: 170
            )
            heroFrame = sourceFrame ?? fallbackFrame
            store.heroAnchorOutfitId = anchorId
            heroOpacity = 1
            heroTransitioning = true

            // Step 2: Cinematic blur-out of the source view
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.5)) {
                store.viewTransitionPhase = .sourceOut
            }

            // Wait for source to blur away
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { cleanupHero(); return }

            // Step 3: Switch the underlying view (hidden by blur + hero on top)
            store.selectedOutfitId = nil
            if goingToCalendar {
                store.pendingCalendarScrollOutfitId = anchorId
            }
            store.currentView = goingToCalendar ? .calendar : .list

            // Step 4: Wait for scroll + layout
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { cleanupHero(); return }

            // Step 5: Find target frame
            var targetFrame: CGRect?
            for _ in 0..<20 {
                let frames = goingToCalendar ? store.calendarOutfitFrames : store.listOutfitFrames
                if let frame = frames[anchorId], frame.width > 0, frame.height > 0 {
                    targetFrame = frame
                    break
                }
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { cleanupHero(); return }
            }

            guard !Task.isCancelled else { cleanupHero(); return }

            // Step 6: Start hero flight
            if let targetFrame {
                startHeroRotation(outfit: outfit, startFrame: frameIndex)
                withAnimation(.timingCurve(0.45, 0, 0.22, 1, duration: 1.0)) {
                    heroFrame = targetFrame
                }
            }

            // Step 7: Cinematic reveal of the target view (staggered, while hero is mid-flight)
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { cleanupHero(); return }

            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)) {
                store.viewTransitionPhase = .targetIn
            }

            // Wait for hero to finish landing
            let remainingFlight: Int = targetFrame != nil ? 650 : 0
            if remainingFlight > 0 {
                try? await Task.sleep(for: .milliseconds(remainingFlight))
            }
            guard !Task.isCancelled else { cleanupHero(); return }

            // Step 8: Reveal real outfit, fade out hero
            store.heroAnchorOutfitId = nil

            withAnimation(.easeOut(duration: 0.12)) {
                heroOpacity = 0
            }

            try? await Task.sleep(for: .milliseconds(150))

            // Step 9: Settle to idle
            withAnimation(.easeOut(duration: 0.2)) {
                store.viewTransitionPhase = .idle
            }
            cleanupHero()
        }
    }

    private func startHeroRotation(outfit: Outfit, startFrame: Int) {
        let frameCount = outfit.frameCount
        guard frameCount > 1 else { return }

        Task { @MainActor in
            let startTime = CACurrentMediaTime()
            let duration: Double = 0.9

            while heroTransitioning {
                let elapsed = CACurrentMediaTime() - startTime
                let progress = min(elapsed / duration, 1.0)

                // Smoothstep easing: 65% linear + 35% hermite
                let smoothStep = progress * progress * (3 - 2 * progress)
                let eased = progress + (smoothStep - progress) * 0.35

                let frameOffset = Int(eased * Double(frameCount))
                let newIndex = ((startFrame + frameOffset) % frameCount + frameCount) % frameCount

                if newIndex != heroFrameIndex {
                    heroFrameIndex = newIndex
                    heroImage = await FrameLoader.shared.frame(for: outfit, index: newIndex)
                }

                if progress >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func cleanupHero() {
        heroTransitioning = false
        heroOutfit = nil
        heroImage = nil
        heroOpacity = 0
        heroFrame = .zero
        heroFrameIndex = 0
        store.heroAnchorOutfitId = nil
        if store.viewTransitionPhase != .idle {
            store.viewTransitionPhase = .idle
        }
    }

    private func viewTransitionHero(outfit: Outfit) -> some View {
        GeometryReader { geometry in
            let viewportFrame = geometry.frame(in: .global)
            let displayFrame = CGRect(
                x: heroFrame.minX - viewportFrame.minX,
                y: heroFrame.minY - viewportFrame.minY,
                width: heroFrame.width,
                height: heroFrame.height
            )

            Group {
                if let heroImage {
                    Image(uiImage: heroImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(width: displayFrame.width, height: displayFrame.height)
            .position(x: displayFrame.midX, y: displayFrame.midY)
            .opacity(heroOpacity)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var logoView: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            store.selectedOutfitId = nil
            store.currentView = .list
        } label: {
            Group {
                if let logoURL = Bundle.main.url(forResource: "logo", withExtension: "png"),
                   let data = try? Data(contentsOf: logoURL),
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 34)
                        .colorMultiply(.black)
                        .opacity(0.82)
                } else {
                    Text("YAFA")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(AppPalette.textPrimary.opacity(0.82))
                }
            }
        }
        .frame(minHeight: 44)
        .buttonStyle(.plain)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
                tabItem(icon: .grid, iconSize: 22, label: "Home", tab: .list)
                tabItem(icon: .plusCircle, iconSize: 26, label: "Upload", tab: .upload)
                tabItem(icon: .globe, iconSize: 24, label: "Public", tab: .feed)
                tabItem(icon: .person, iconSize: 22, label: "Profile", tab: .profile)
            }
            .padding(.horizontal, LayoutMetrics.large)
            .padding(.vertical, LayoutMetrics.xxSmall)
            .background {
                ZStack {
                    LightBlurView(style: .systemThinMaterialLight)
                        .clipShape(Capsule(style: .continuous))
                    Capsule(style: .continuous).fill(AppPalette.cardFill)
                }
            }
            .overlay(Capsule(style: .continuous).strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.12), radius: 20, y: 10)
            .shadow(color: Color.black.opacity(0.06), radius: 6, y: 3)
            .padding(.horizontal, LayoutMetrics.xLarge)
            .padding(.bottom, LayoutMetrics.xxSmall)
    }

    private func tabItem(icon: AppIconGlyph, iconSize: CGFloat = 24, label: String, tab: AppView) -> some View {
        let isActive = store.currentView == tab || (tab == .list && store.currentView == .calendar)
        let showsUploadActivity = tab == .upload && store.isUploadInProgress
        return Button {
            let targetTab = (tab == .list && store.currentView == .calendar) ? AppView.list : tab
            if store.currentView == targetTab {
                // Already on this tab — refresh feed if on feed
                if tab == .feed {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    store.feedScrollToTopTrigger += 1
                }
                return
            }
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()

            store.selectedOutfitId = nil
            store.currentView = targetTab
        } label: {
            VStack(spacing: LayoutMetrics.xxxSmall) {
                ZStack(alignment: .topTrailing) {
                    if tab == .upload {
                        UploadTabIconView(
                            isActive: isActive,
                            isAnimating: showsUploadActivity,
                            progress: store.uploadIndicatorProgress
                        )
                    } else {
                        AppIcon(
                            glyph: icon,
                            size: iconSize,
                            color: isActive ? AppPalette.iconActive : AppPalette.iconFaint
                        )
                        .frame(width: 36, height: 36)
                    }

                    if tab == .feed && store.unreadNotificationCount > 0 {
                        Text("\(store.unreadNotificationCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppPalette.uploadGlow.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background {
                                LightBlurView(style: .systemThinMaterialLight)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .fill(Color.white.opacity(0.96))
                                    )
                            }
                            .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                            .shadow(color: AppPalette.uploadGlow.opacity(0.2), radius: 3, y: 1)
                            .offset(x: 8, y: -5)
                    }

                    if showsUploadActivity {
                        Text("1")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppPalette.uploadGlow)
                            .frame(width: 18, height: 18)
                            .background {
                                LightBlurView(style: .systemThinMaterialLight)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .fill(Color.white.opacity(0.96))
                                            .shadow(
                                                color: AppPalette.uploadGlow.opacity(0.55),
                                                radius: 8,
                                                y: 0
                                            )
                                    )
                            }
                            .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                            .offset(x: 8, y: -5)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var tempToggle: some View {
        HStack(spacing: 2) {
            temperatureOption(label: "°F", isSelected: store.useFahrenheit) {
                setTemperatureUnit(true)
            }
            temperatureOption(label: "°C", isSelected: !store.useFahrenheit) {
                setTemperatureUnit(false)
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.98))
        )
        .overlay(
            Capsule()
                .stroke(Color(red: 0.88, green: 0.89, blue: 0.91).opacity(0.9), lineWidth: 0.8)
        )
        .padding(8)
        .contentShape(Rectangle())
    }

    private func viewModeOption(glyph: AppIconGlyph, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        } label: {
            AppIcon(glyph: glyph, size: 12, color: isSelected ? AppPalette.textPrimary : AppPalette.textFaint)
                .frame(width: 40, height: 24)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.06), radius: 3, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func temperatureOption(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
    }

    private func setTemperatureUnit(_ useFahrenheit: Bool) {
        guard store.useFahrenheit != useFahrenheit else { return }
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        withAnimation(.easeInOut(duration: 0.18)) {
            store.useFahrenheit = useFahrenheit
        }
    }


    private var floatingFavoritesButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            showsFavoritesSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon(
                    glyph: .heart,
                    size: 16,
                    color: AppPalette.iconPrimary,
                    filled: store.likedIds.contains(where: { id in store.outfits.contains { $0.id == id } })
                )
                    .frame(width: 48, height: 48)
                    .appCircle()
                let ownLikedCount = store.likedIds.filter { id in store.outfits.contains { $0.id == id } }.count
                if ownLikedCount > 0 {
                    Text("\(ownLikedCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(width: 20, height: 20)
                        .background {
                            LightBlurView(style: .systemThinMaterialLight)
                                .clipShape(Circle())
                                .overlay(Circle().fill(AppPalette.cardFill))
                        }
                        .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                        .shadow(color: AppPalette.cardShadow, radius: 4, y: 2)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            Group {
                if Bundle.main.url(forResource: "Loader", withExtension: "json") != nil {
                    LottieView(animation: .named("Loader"))
                        .looping()
                        .frame(width: 98, height: 98)
                } else {
                    VStack(spacing: LayoutMetrics.xSmall) {
                        ProgressView()
                        Text("LOADING ARCHIVE")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(2)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                }
            }
        }
        .opacity(loaderVisible ? 1 : 0)
        .allowsHitTesting(loaderVisible)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: AppConfig.loaderFadeDuration), value: loaderVisible)
    }

    private func syncLoadingOverlay(isLoading: Bool) {
        loaderDismissTask?.cancel()

        if isLoading {
            loaderMounted = true
            loaderVisible = true
            return
        }

        loaderVisible = false
        loaderDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(AppConfig.loaderFadeDuration * 1000)))
            guard !Task.isCancelled else { return }
            loaderMounted = false
        }
    }

    // MARK: - Review Notification Banner

    private var reviewBanner: some View {
        Button {
            dismissReviewBanner()
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            store.currentView = .upload
        } label: {
            HStack(spacing: 6) {
                AppIcon(glyph: .check, size: 12, color: AppPalette.uploadGlow)
                Text("Your fit is ready")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppPalette.uploadGlow)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .appCapsule()
            .shadow(color: AppPalette.uploadGlow.opacity(0.2), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.top, 54)
        .scaleEffect(showReviewBanner ? 1 : 0.85)
    }

    private func presentReviewBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            showReviewBanner = true
        }
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            dismissReviewBanner()
        }
    }

    private func dismissReviewBanner() {
        bannerDismissTask?.cancel()
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.3)) {
            showReviewBanner = false
        }
    }

    private var backgroundColor: Color {
        store.currentView == .feed ? AppPalette.groupedBackground : AppPalette.pageBackground
    }
}

private struct UploadTabIconView: View {
    let isActive: Bool
    let isAnimating: Bool
    let progress: Double

    var body: some View {
        ZStack {
            if isAnimating {
                ZStack {
                    // Outer halo — wide soft diffuse glow
                    Circle()
                        .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                        .stroke(AppPalette.uploadGlow.opacity(0.18), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .blur(radius: 5)
                        .rotationEffect(.degrees(-90))

                    // Mid glow
                    Circle()
                        .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                        .stroke(AppPalette.uploadGlow.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .blur(radius: 1.5)
                        .rotationEffect(.degrees(-90))

                    // Soft white core
                    Circle()
                        .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                        .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                        .blur(radius: 0.2)
                        .rotationEffect(.degrees(-90))
                        .shadow(color: AppPalette.uploadGlow.opacity(0.45), radius: 1.2, y: 0)
                }
                .frame(width: 36, height: 36)
                .animation(.easeInOut(duration: 1.1), value: progress)
            }

            AppIcon(
                glyph: .plusCircle,
                size: 26,
                color: isActive ? AppPalette.iconActive : AppPalette.iconFaint
            )
            .frame(width: 36, height: 36)
        }
    }
}

private struct FavoritesSheetView: View {
    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var favoriteOutfits: [Outfit] {
        store.sortedOutfits.filter { store.likedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.medium) {
                    Text("Your liked outfits live here.")
                        .font(.system(size: 13))
                        .foregroundStyle(AppPalette.textMuted)

                    if favoriteOutfits.isEmpty {
                        VStack(spacing: LayoutMetrics.small) {
                            AppIcon(
                                glyph: .heart,
                                size: 18,
                                color: AppPalette.textMuted.opacity(0.92)
                            )
                                .frame(width: 48, height: 48)
                                .appCircle(shadowRadius: 0, shadowY: 0)

                            Text("No favorites yet")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AppPalette.textStrong)

                            Text("Tap the heart on an outfit and it will show up here.")
                                .font(.system(size: 12))
                                .foregroundStyle(AppPalette.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LayoutMetrics.xLarge)
                    } else {
                        LazyVStack(spacing: LayoutMetrics.small) {
                            ForEach(favoriteOutfits) { outfit in
                                favoriteOutfitRow(outfit)
                            }
                        }
                    }
                }
                .padding(LayoutMetrics.screenPadding)
                .padding(.bottom, LayoutMetrics.large)
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textPrimary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppPalette.groupedBackground)
    }

    private func favoriteOutfitRow(_ outfit: Outfit) -> some View {
        HStack(spacing: LayoutMetrics.small) {
            RotatableOutfitImage(
                outfit: outfit,
                height: 126,
                eagerLoad: true
            )
            .frame(width: 94)

            VStack(alignment: .leading, spacing: 6) {
                Text(outfit.fullDateLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                if let weather = outfit.weather {
                    WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
                }

                if let tags = outfit.tags, tags.isEmpty == false {
                    Text(tags.prefix(3).joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppPalette.textMuted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(LayoutMetrics.small)
        .appCard(cornerRadius: 20, shadowRadius: 0, shadowY: 0)
    }
}

#Preview {
    RootView()
        .environment(OutfitStore())
}
