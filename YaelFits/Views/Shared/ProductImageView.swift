import SwiftUI

struct LinkedTagSelection: Identifiable {
    let id: String

    var tag: String { id }
}

struct ProductImageView: View {
    let product: Product
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.28))

            if let imageURL = product.resolvedImageURL {
                AsyncImage(url: imageURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    case .failure:
                        fallbackLabel
                    case .empty:
                        ProgressView()
                            .tint(AppPalette.textPrimary)
                    @unknown default:
                        fallbackLabel
                    }
                }
            } else {
                fallbackLabel
            }
        }
        .frame(width: size, height: size)
        .appRoundedRect(cornerRadius: cornerRadius, shadowRadius: 0, shadowY: 0)
    }

    private var fallbackLabel: some View {
        Text(product.displayName)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(AppPalette.textMuted)
            .multilineTextAlignment(.center)
            .padding(6)
    }
}

struct EmptyProductCard: View {
    var body: some View {
        VStack(spacing: 6) {
            AppIcon(
                glyph: .plusCircle,
                size: 18,
                color: AppPalette.textMuted.opacity(0.92)
            )
                .frame(width: 64, height: 64)
                .appRoundedRect(cornerRadius: 14, shadowRadius: 0, shadowY: 0)

            Text("Add a product")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppPalette.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 88)
        }
    }
}

struct LinkedProductOutfitsSheet: View {
    let product: Product
    let sourceOutfit: Outfit

    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var linkedOutfits: [Outfit] {
        store.sortedOutfits.filter { outfit in
            outfit.id != sourceOutfit.id &&
            (outfit.products ?? []).contains(where: { $0.id == product.id })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.medium) {
                    HStack(spacing: LayoutMetrics.small) {
                        ProductImageView(product: product, size: 68, cornerRadius: 18)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(product.displayName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(AppPalette.textStrong)

                            Text("Shown in other outfits")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppPalette.textMuted)
                        }
                    }

                    if linkedOutfits.isEmpty {
                        Text("No linked outfits found yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, LayoutMetrics.large)
                    } else {
                        LazyVStack(spacing: LayoutMetrics.small) {
                            ForEach(linkedOutfits) { outfit in
                                LinkedOutfitRow(outfit: outfit)
                            }
                        }
                    }
                }
                .padding(LayoutMetrics.screenPadding)
                .padding(.bottom, LayoutMetrics.large)
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Linked Outfits")
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
}

struct LinkedTagOutfitsSheet: View {
    let tag: String
    let sourceOutfit: Outfit

    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var linkedOutfits: [Outfit] {
        store.sortedOutfits.filter { outfit in
            outfit.id != sourceOutfit.id &&
            (outfit.tags ?? []).contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutMetrics.medium) {
                    VStack(alignment: .leading, spacing: 8) {
                        TagPill(tag: tag)

                        Text("Shown in other outfits")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppPalette.textMuted)
                    }

                    if linkedOutfits.isEmpty {
                        Text("No linked outfits found yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(AppPalette.textMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, LayoutMetrics.large)
                    } else {
                        LazyVStack(spacing: LayoutMetrics.small) {
                            ForEach(linkedOutfits) { outfit in
                                LinkedOutfitRow(outfit: outfit)
                            }
                        }
                    }
                }
                .padding(LayoutMetrics.screenPadding)
                .padding(.bottom, LayoutMetrics.large)
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Linked Outfits")
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
}

private struct LinkedOutfitRow: View {
    let outfit: Outfit

    @Environment(OutfitStore.self) private var store

    var body: some View {
        HStack(spacing: LayoutMetrics.small) {
            RotatableOutfitImage(
                outfit: outfit,
                height: 112,
                eagerLoad: true
            )
            .frame(width: 84)

            VStack(alignment: .leading, spacing: 6) {
                Text(outfit.fullDateLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)

                if let weather = outfit.weather {
                    WeatherPill(weather: weather, useFahrenheit: store.useFahrenheit)
                }

                if let tags = outfit.tags, tags.isEmpty == false {
                    Text(tags.prefix(2).joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppPalette.textMuted)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(LayoutMetrics.small)
        .appCard(cornerRadius: 20, shadowRadius: 0, shadowY: 0)
    }
}
