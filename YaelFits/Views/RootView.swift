import SwiftUI
import Lottie

struct RootView: View {
    @Environment(OutfitStore.self) private var store

    private let headerContentInset: CGFloat = 0

    @State private var loaderMounted = true
    @State private var loaderVisible = true
    @State private var loaderDismissTask: Task<Void, Never>?
    @State private var showsFavoritesSheet = false

    var body: some View {
        @Bindable var store = store

        ZStack(alignment: .top) {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                switch store.currentView {
                case .list:
                    OutfitGridView()
                case .calendar:
                    CalendarMonthView()
                case .feed:
                    PublicFeedListView()
                case .upload:
                    UploadPipelineView()
                }
            }
            .padding(.top, headerContentInset)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
            }
            .zIndex(90)

            CalendarDetailOverlayHost()
                .zIndex(140)

            if showsFloatingButtons {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        floatingWaitlistButton
                        Spacer()
                        floatingFavoritesButton
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, 64)
                }
                .zIndex(65)
            }

            VStack {
                Spacer()
                tabBar
            }
            .ignoresSafeArea(edges: .bottom)
            .zIndex(100)

            if loaderMounted {
                loadingOverlay
                    .zIndex(999)
            }
        }
        .task {
            await store.loadData()
        }
        .onAppear {
            syncLoadingOverlay(isLoading: store.isLoading)
        }
        .onChange(of: store.isLoading) { _, isLoading in
            syncLoadingOverlay(isLoading: isLoading)
        }
        .onDisappear {
            loaderDismissTask?.cancel()
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
            tempToggle
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, LayoutMetrics.xSmall)
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
                    Text("YAEL FITS")
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
        VStack(spacing: 0) {
            Divider()
                .opacity(0.16)

            HStack(spacing: 0) {
                tabItem(icon: .grid, label: "Home", tab: .list)
                tabItem(icon: .calendar, label: "Calendar", tab: .calendar)
                tabItem(icon: .plusCircle, label: "Upload", tab: .upload)
                tabItem(icon: .globe, label: "Public", tab: .feed)
            }
            .padding(.horizontal, LayoutMetrics.xxSmall)
            .padding(.top, LayoutMetrics.xSmall)
            .padding(.bottom, LayoutMetrics.medium)
        }
        .background {
            LightBlurView(style: .systemThinMaterialLight)
                .overlay(Rectangle().fill(AppPalette.cardFill))
        }
    }

    private func tabItem(icon: AppIconGlyph, label: String, tab: AppView) -> some View {
        let isActive = store.currentView == tab
        let showsUploadActivity = tab == .upload && store.isUploadInProgress
        return Button {
            guard store.currentView != tab else { return }
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()

            if tab == .calendar, store.currentView == .list {
                store.pendingCalendarScrollOutfitId = store.centeredListOutfitId ?? store.sortedOutfits.first?.id
            }

            store.selectedOutfitId = nil
            store.currentView = tab
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
                            size: 20,
                            color: isActive ? AppPalette.iconActive : AppPalette.iconFaint
                        )
                        .frame(width: 28, height: 28)
                    }

                    if showsUploadActivity {
                        Text("1")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 0.58, green: 0.28, blue: 0.46))
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
                .frame(width: 32, height: 32)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? AppPalette.textPrimary : AppPalette.textFaint)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
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

    private var floatingWaitlistButton: some View {
        Button {} label: {
            Text("GET ON THE WAITLIST")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.2)
                .textCase(.uppercase)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(AppPalette.textMuted)
                .padding(.horizontal, 16)
                .frame(minHeight: LayoutMetrics.touchTarget)
                .appCapsule()
        }
        .buttonStyle(.plain)
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
                    filled: !store.likedIds.isEmpty
                )
                    .frame(width: 48, height: 48)
                    .appCircle()
                if !store.likedIds.isEmpty {
                    Text("\(store.likedIds.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(width: 20, height: 20)
                        .background {
                            LightBlurView(style: .systemThinMaterialLight)
                                .clipShape(Circle())
                                .overlay(Circle().fill(AppPalette.cardFill))
                        }
                        .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
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
                Circle()
                    .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                    .stroke(
                        AppPalette.uploadGlow.opacity(0.96),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                    )
                    .frame(width: 28, height: 28)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: AppPalette.uploadGlow.opacity(0.55), radius: 5, y: 0)
                    .overlay {
                        Circle()
                            .trim(from: 0, to: max(0.06, min(progress, 0.98)))
                            .stroke(
                                AppPalette.uploadGlow.opacity(0.28),
                                style: StrokeStyle(lineWidth: 5.5, lineCap: .round)
                            )
                            .frame(width: 28, height: 28)
                            .rotationEffect(.degrees(-90))
                            .blur(radius: 4)
                    }
                    .animation(.easeInOut(duration: 1.1), value: progress)
            }

            AppIcon(
                glyph: .plusCircle,
                size: 20,
                color: isActive ? AppPalette.iconActive : AppPalette.iconFaint
            )
            .frame(width: 28, height: 28)
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
