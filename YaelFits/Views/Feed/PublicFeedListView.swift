import SwiftUI

struct PublicFeedListView: View {
    @Environment(OutfitStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.large) {
                ForEach(store.feedPosts) { post in
                    FeedPostCard(post: post)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.top, LayoutMetrics.feedTopInset)
            .padding(.bottom, LayoutMetrics.bottomOverlayInset)
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollIndicators(.hidden)
        .background(AppPalette.groupedBackground)
    }
}

struct FeedPostCard: View {
    let post: FeedPost
    @Environment(OutfitStore.self) private var store

    private var outfit: Outfit? {
        store.outfitById[post.outfitId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            cardHeader

            if let outfit {
                outfitContent(outfit)
            }

            if metadataLabels.isEmpty == false {
                metadataRow
            }

            if let caption = post.caption, caption.isEmpty == false {
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
        .scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.985)
                .opacity(phase.isIdentity ? 1 : 0.96)
        }
    }

    private var cardHeader: some View {
        HStack(spacing: LayoutMetrics.xSmall) {
            profileAvatar

            VStack(alignment: .leading, spacing: 2) {
                Text(post.authorName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                Text(timestampLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(AppPalette.textFaint)
            }

            Spacer()

            if let weather = outfit?.weather, weather.condition.isEmpty == false {
                WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
            }
        }
    }

    private var profileAvatar: some View {
        Group {
            if let url = post.profileImageURL,
               let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.clear
                    .overlay {
                        Text(String(post.authorName.prefix(1)).uppercased())
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppPalette.textPrimary)
                    }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .appCircle(shadowRadius: 0, shadowY: 0)
    }

    private func outfitContent(_ outfit: Outfit) -> some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.small) {
            RotatableOutfitImage(
                outfit: outfit,
                height: 292,
                draggable: true,
                preloadFullSequenceOnAppear: true
            )
                .frame(maxWidth: .infinity)

            if let products = outfit.products, products.isEmpty == false {
                productRow(products)
            }
        }
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

    private func productRow(_ products: [Product]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LayoutMetrics.small) {
                ForEach(products) { product in
                    productItem(product)
                }
            }
        }
    }

    private func productItem(_ product: Product) -> some View {
        VStack(spacing: LayoutMetrics.xxSmall) {
            ProductImageView(product: product, size: 56, cornerRadius: 14)

            Text(product.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 78)
        }
    }

    private var cardActions: some View {
        HStack(spacing: LayoutMetrics.xxSmall) {
            actionButton(
                icon: .heart,
                filled: store.feedLikedPostIds.contains(post.id),
                isActive: store.feedLikedPostIds.contains(post.id)
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.toggleFeedLike(post.id)
                }
            }
            actionButton(
                icon: .comment,
                isActive: store.feedCommentedPostIds.contains(post.id)
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.toggleFeedComment(post.id)
                }
            }
            actionButton(
                icon: .bookmark,
                filled: store.feedSavedPostIds.contains(post.id),
                isActive: store.feedSavedPostIds.contains(post.id)
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    store.toggleFeedSave(post.id)
                }
            }
            Spacer()
        }
        .padding(.top, LayoutMetrics.xxxSmall)
    }

    private var timestampLabel: String {
        guard let parsedDate = outfit?.parsedDate else {
            return "2H AGO"
        }

        let hoursSincePost = Calendar.current.dateComponents([.hour], from: parsedDate, to: Date()).hour ?? 0
        if hoursSincePost >= 24 {
            return outfit?.monthDayLabel.uppercased() ?? "2H AGO"
        }

        return "2H AGO"
    }

    private func actionButton(
        icon: AppIconGlyph,
        filled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            AppIcon(
                glyph: icon,
                size: 14,
                color: isActive ? AppPalette.iconActive : AppPalette.iconPrimary,
                filled: filled
            )
                .frame(width: 40, height: 40)
                .appCircle(shadowRadius: 0, shadowY: 0)
                .scaleEffect(isActive ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .frame(minWidth: LayoutMetrics.touchTarget, minHeight: LayoutMetrics.touchTarget)
    }
}
