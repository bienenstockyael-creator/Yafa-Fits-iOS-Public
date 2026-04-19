import SwiftUI

struct PublicFeedListView: View {
    @Environment(OutfitStore.self) private var store
    @State private var showDiscover = false
    @State private var hasRefreshedFeed = false
    @State private var hasScrolled = false
    @State private var likeCounts: [String: Int] = [:]
    @State private var commentCounts: [String: Int] = [:]
    @State private var myLikedOutfitIds: Set<String> = []
    @State private var showsNotifications = false

    var body: some View {
        ZStack(alignment: .top) {
            // Layer 1: Background
            AppPalette.groupedBackground.ignoresSafeArea()

            // Layer 2: Header
            feedHeader
                .zIndex(1)

            // Layer 3: Cards (above header)
            Group {
                if store.feedPosts.isEmpty {
                    emptyState
                } else {
                    feedList
                }
            }
            .zIndex(2)

            // Layer 4: Floating notification (top right, fades out on scroll)
            VStack {
                HStack {
                    Spacer()
                    floatingNotificationButton
                        .opacity(hasScrolled ? 0 : 1)
                        .scaleEffect(hasScrolled ? 0.3 : 1, anchor: .center)
                        .animation(.easeOut(duration: 0.12), value: hasScrolled)
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, 12)
                Spacer()
            }
            .allowsHitTesting(!hasScrolled)
            .zIndex(3)

            // Layer 5: Floating search (bottom right, fades in on scroll)
            if !store.feedPosts.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        floatingSearchButton
                            .opacity(hasScrolled ? 1 : 0)
                            .scaleEffect(hasScrolled ? 1 : 0.3, anchor: .center)
                            .animation(.easeOut(duration: 0.12), value: hasScrolled)
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                    .padding(.bottom, 64)
                }
                .allowsHitTesting(hasScrolled)
                .zIndex(4)
            }
        }
        .task {
            guard !hasRefreshedFeed else { return }
            hasRefreshedFeed = true
            await store.refreshFeed()
            await loadCounts()
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverView()
                .environment(store)
        }
    }

    private var feedList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.large) {
                Color.clear.frame(height: 0).id("feedTop")
                searchBar
                    .padding(.top, LayoutMetrics.feedTopInset)

                ForEach(store.feedPosts) { post in
                    FeedPostCard(
                        post: post,
                        likeCount: likeCounts[post.outfitId] ?? 0,
                        commentCount: commentCounts[post.outfitId] ?? 0,
                        isInitiallyLiked: myLikedOutfitIds.contains(post.outfitId),
                        onCommentCountChanged: { newCount in
                            commentCounts[post.outfitId] = newCount
                        }
                    )
                }
            }
            .scrollTargetLayout()
            .animation(.easeOut(duration: 0.3), value: store.feedPosts.count)
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.bottom, LayoutMetrics.bottomOverlayInset)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.frame(in: .named("feedScroll")).minY) { _, newY in
                            let scrolled = newY < -20
                            if scrolled != hasScrolled {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    hasScrolled = scrolled
                                }
                            }
                        }
                }
            }
        }
        .coordinateSpace(name: "feedScroll")
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .contentMargins(.top, 20, for: .scrollContent)
        .scrollIndicators(.hidden)
        .refreshable {
            await store.refreshFeed()
        }
        .onChange(of: store.feedScrollToTopTrigger) { _, _ in
            withAnimation { proxy.scrollTo("feedTop", anchor: .top) }
            Task {
                hasRefreshedFeed = false
                await store.refreshFeed()
                await loadCounts()
            }
        }
        } // ScrollViewReader
    }

    private var searchBar: some View {
        Button {
            showDiscover = true
        } label: {
            HStack(spacing: LayoutMetrics.xxSmall) {
                AppIcon(glyph: .search, size: 14, color: AppPalette.textFaint)
                Text("Find your people")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textFaint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .appCard(cornerRadius: 14, shadowRadius: 4, shadowY: 2)
        }
        .buttonStyle(.plain)
        .opacity(hasScrolled ? 0 : 1)
    }

    private var feedHeader: some View {
        HStack {
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

            Spacer()
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, LayoutMetrics.xSmall)
    }

    private var floatingNotificationButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showsNotifications = true
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon(glyph: .bell, size: 16, color: AppPalette.iconPrimary)
                    .frame(width: 48, height: 48)
                    .appCircle()

                if store.unreadNotificationCount > 0 {
                    Text("\(store.unreadNotificationCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Color.red, in: Circle())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsNotifications) {
            NotificationsPlaceholderSheet()
                .environment(store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppPalette.groupedBackground)
        }
    }

    private var floatingSearchButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showDiscover = true
        } label: {
            AppIcon(glyph: .search, size: 16, color: AppPalette.iconPrimary)
                .frame(width: 48, height: 48)
                .appCircle(shadowRadius: 12, shadowY: 6)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.medium) {
            Spacer()

            VStack(spacing: LayoutMetrics.small) {
                AppIcon(glyph: .globe, size: 32, color: AppPalette.textMuted)

                Text("Your feed is empty")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                Text("Follow people to see their outfits here")
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textMuted)
                    .multilineTextAlignment(.center)
            }

            Button {
                showDiscover = true
            } label: {
                HStack(spacing: 6) {
                    AppIcon(glyph: .search, size: 14, color: AppPalette.textPrimary)
                    Text("FIND YOUR PEOPLE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(AppPalette.textPrimary)
                }
                .frame(height: 48)
                .padding(.horizontal, 28)
                .appCapsule(shadowRadius: 8, shadowY: 4)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
    }

    private func loadCounts() async {
        let outfitIds = store.feedPosts.map(\.outfitId)
        guard !outfitIds.isEmpty, let userId = store.userId else { return }

        async let likesTask = try? SocialService.getLikeCounts(outfitIds: outfitIds)
        async let commentsTask = try? SocialService.getCommentCounts(outfitIds: outfitIds)
        async let myLikesTask = try? SocialService.getLikedOutfitIds(userId: userId)

        let likes = await likesTask ?? [:]
        let comments = await commentsTask ?? [:]
        let myLikes = await myLikesTask ?? []

        await MainActor.run {
            likeCounts = likes
            commentCounts = comments
            myLikedOutfitIds = myLikes
        }
    }
}

struct FeedPostCard: View {
    let post: FeedPost
    var likeCount: Int
    var commentCount: Int
    var isInitiallyLiked: Bool
    var onCommentCountChanged: ((Int) -> Void)?
    @Environment(OutfitStore.self) private var store
    @State private var showComments = false
    @State private var showUserProfile = false
    @State private var likeToggled = false
    @State private var localLikeAdjustment: Int = 0
    @State private var localCommentCount: Int?
    @State private var cartOpen = false
    @State private var fetchedOutfit: Outfit?

    // Use local store first, then prefetch cache, then per-card fetch
    private var outfit: Outfit? {
        store.outfitById[post.outfitId] ?? store.feedOutfitCache[post.outfitId] ?? fetchedOutfit
    }

    @State private var cardVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            cardHeader

            if let outfit {
                outfitContent(outfit)
            }

            if metadataLabels.isEmpty == false {
                metadataRow
            }

            if let caption = outfit?.caption ?? post.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            cardActions
        }
        .padding(LayoutMetrics.medium)
        .appCard()
        .opacity(cardVisible ? 1 : 0)
        .scaleEffect(cardVisible ? 1 : 0.96)
        .onChange(of: outfit) { _, newOutfit in
            guard newOutfit != nil, !cardVisible else { return }
            withAnimation(.easeOut(duration: 0.3)) { cardVisible = true }
        }
        .onAppear {
            if outfit != nil { cardVisible = true }
        }
        .sheet(isPresented: $showComments, onDismiss: {
            Task {
                let counts = try? await SocialService.getCommentCounts(outfitIds: [post.outfitId])
                let newCount = counts?[post.outfitId] ?? displayCommentCount
                await MainActor.run {
                    localCommentCount = newCount
                }
                onCommentCountChanged?(newCount)
            }
        }) {
            CommentsSheet(outfitId: post.outfitId)
                .environment(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppPalette.groupedBackground)
        }
        .task(id: post.outfitId) {
            // If outfit isn't in local store (another user's outfit), fetch from Supabase
            guard store.outfitById[post.outfitId] == nil else { return }
            if let remote = await ContentSource.getPublicOutfit(id: post.outfitId) {
                await MainActor.run { fetchedOutfit = remote }
            }
        }
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.985)
                .opacity(phase.isIdentity ? 1 : 0.96)
        }
    }

    private var cardHeader: some View {
        HStack(spacing: LayoutMetrics.xSmall) {
            Button {
                if post.authorId != nil { showUserProfile = true }
            } label: {
                HStack(spacing: LayoutMetrics.xSmall) {
                    profileAvatar
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(post.authorName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AppPalette.textStrong)
                            if post.isAuthorPro == true {
                                Text("PRO")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .tracking(1)
                                    .foregroundStyle(AppPalette.pageBackground)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(AppPalette.textSecondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }
                        Text(timestampLabel)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.3)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showUserProfile) {
                if let authorId = post.authorId {
                    UserProfileSheet(userId: authorId)
                        .environment(store)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(AppPalette.groupedBackground)
                        .presentationCornerRadius(20)
                }
            }

            Spacer()

            if let weather = outfit?.weather, weather.condition.isEmpty == false {
                WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
            }
        }
    }

    private var profileAvatar: some View {
        AvatarView(
            url: post.avatarUrl,
            initial: String(post.authorName.prefix(1)).uppercased()
        )
    }

    private func outfitContent(_ outfit: Outfit) -> some View {
        RotatableOutfitImage(
            outfit: outfit,
            height: 292,
            draggable: true,
            preloadFullSequenceOnAppear: true
        )
        .frame(maxWidth: .infinity)
    }

    private var metadataLabels: [String] {
        [
            post.height.map { "Height \($0)" },
            post.size.map { "Size \($0)" },
        ]
        .compactMap { $0 }
    }

    private var metadataRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LayoutMetrics.xxSmall) {
                ForEach(metadataLabels, id: \.self) { label in
                    metadataChip(label)
                }
            }
        }
    }

    private func metadataChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppPalette.textMuted)
            .padding(.horizontal, LayoutMetrics.xSmall)
            .padding(.vertical, 7)
            .appCapsule(shadowRadius: 0, shadowY: 0)
    }

    private var displayLiked: Bool {
        likeToggled ? !isInitiallyLiked : isInitiallyLiked
    }

    private var displayLikeCount: Int {
        max(0, likeCount + localLikeAdjustment)
    }

    private var displayCommentCount: Int {
        localCommentCount ?? commentCount
    }

    private var hasProducts: Bool {
        outfit?.products?.isEmpty == false
    }

    private var cardActions: some View {
        VStack(spacing: 0) {
            HStack(spacing: LayoutMetrics.xxSmall) {
                actionButton(
                    icon: .heart,
                    count: displayLikeCount,
                    filled: displayLiked,
                    isActive: displayLiked
                ) {
                    guard let userId = store.userId else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        let wasLiked = displayLiked
                        likeToggled.toggle()
                        localLikeAdjustment += wasLiked ? -1 : 1
                        Task {
                            if wasLiked {
                                try? await SocialService.unlikeOutfit(userId: userId, outfitId: post.outfitId)
                            } else {
                                try? await SocialService.likeOutfit(userId: userId, outfitId: post.outfitId)
                            }
                        }
                    }
                }
                actionButton(
                    icon: .comment,
                    count: displayCommentCount
                ) {
                    showComments = true
                }
                actionButton(
                    icon: .bookmark,
                    filled: store.savedIds.contains(post.outfitId),
                    isActive: store.savedIds.contains(post.outfitId)
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.toggleSave(post.outfitId)
                    }
                }

                if hasProducts {
                    actionButton(
                        icon: .cart,
                        isActive: cartOpen
                    ) {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) {
                            cartOpen.toggle()
                        }
                    }
                }

                Spacer()
            }
            .padding(.top, LayoutMetrics.xxxSmall)

            if cartOpen, let products = outfit?.products, !products.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
                            VStack(spacing: 6) {
                                ProductImageView(product: product, size: 56, cornerRadius: 14)

                                Button {
                                    // Use direct shop link if available, otherwise fall back to Google Shopping
                                    if let shopLink = product.shopLink,
                                       !shopLink.isEmpty,
                                       let url = URL(string: shopLink) {
                                        UIApplication.shared.open(url)
                                    } else {
                                        let query = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !query.isEmpty,
                                              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                                              let url = URL(string: "https://www.google.com/search?tbm=shop&q=\(encoded)")
                                        else { return }
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    Text("BUY")
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(1.1)
                                        .foregroundStyle(AppPalette.textMuted)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(Color.white.opacity(0.45)))
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8))
                                }
                                .buttonStyle(.plain)
                            }
                            .opacity(cartOpen ? 1 : 0)
                            .scaleEffect(cartOpen ? 1 : 0.85)
                            .animation(
                                .timingCurve(0.22, 1, 0.36, 1, duration: 0.35)
                                    .delay(0.1 + Double(index) * 0.07),
                                value: cartOpen
                            )
                        }
                    }
                    .padding(.vertical, LayoutMetrics.small)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
    }

    private var timestampLabel: String {
        RelativeTime.label(from: post.publishedDate ?? outfit?.parsedDate)
    }

    private func actionButton(
        icon: AppIconGlyph,
        count: Int? = nil,
        filled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                AppIcon(
                    glyph: icon,
                    size: 14,
                    color: isActive ? AppPalette.iconActive : AppPalette.iconPrimary,
                    filled: filled
                )
                .frame(width: 40, height: 40)
                .appCircle(shadowRadius: 0, shadowY: 0)
                .scaleEffect(isActive ? 0.96 : 1)

                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppPalette.textMuted)
                        .frame(minWidth: 16, minHeight: 16)
                        .background {
                            LightBlurView(style: .systemThinMaterialLight)
                                .clipShape(Circle())
                                .overlay(Circle().fill(Color.white.opacity(0.96)))
                        }
                        .overlay(Circle().strokeBorder(AppPalette.cardBorder, lineWidth: 0.75))
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: LayoutMetrics.touchTarget, minHeight: LayoutMetrics.touchTarget)
    }
}
