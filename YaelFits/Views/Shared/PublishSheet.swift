import SwiftUI

// MARK: - Publish sheet

struct PublishSheet: View {
    let outfit: Outfit
    var onPublished: (String?, [Product]) -> Void

    @Environment(OutfitStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var caption: String
    @State private var taggedProducts: [ProductWithShopLink]
    @State private var isPublishing = false
    @State private var publishError: String?
    @State private var showAddProduct = false

    // Shop links available to all users — products only appear on feed if linked

    init(outfit: Outfit, onPublished: @escaping (String?, [Product]) -> Void) {
        self.outfit = outfit
        self.onPublished = onPublished
        _caption = State(initialValue: outfit.caption ?? "")
        _taggedProducts = State(initialValue: (outfit.products ?? []).map {
            ProductWithShopLink(product: $0, shopURL: $0.shopLink ?? "")
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LayoutMetrics.medium) {
                    captionSection
                    productsSection
                    feedNote
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, 100)
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle("Publish to Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppPalette.textMuted)
                }
            }
            .overlay(alignment: .bottom) { publishButton }
            .sheet(isPresented: $showAddProduct) {
                if let userId = store.userId {
                    AddProductSheet(userId: userId, outfitId: outfit.id) { product in
                        let p = Product(name: product.name, price: nil, image: product.imageURL,
                                        productId: product.id, tags: product.tags)
                        taggedProducts.append(ProductWithShopLink(product: p, shopURL: ""))
                    }
                }
            }
            .alert("Couldn't publish", isPresented: .constant(publishError != nil)) {
                Button("OK") { publishError = nil }
            } message: { Text(publishError ?? "") }
        }
    }

    // MARK: - Caption

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            label("CAPTION")
            ZStack(alignment: .topLeading) {
                if caption.isEmpty {
                    Text("Write a caption…")
                        .font(.system(size: 14))
                        .foregroundStyle(AppPalette.textFaint)
                        .padding(.top, 8).padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $caption)
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textPrimary)
                    .frame(minHeight: 80, maxHeight: 140)
                    .scrollContentBackground(.hidden)
            }
            .padding(LayoutMetrics.xSmall)
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        }
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            label("PRODUCTS")

            VStack(spacing: 0) {
                ForEach($taggedProducts) { $entry in
                    productRow(entry: $entry)
                    if entry.id != taggedProducts.last?.id {
                        Divider().opacity(0.5).padding(.leading, 64)
                    }
                }

                if !taggedProducts.isEmpty { Divider().opacity(0.5) }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showAddProduct = true
                } label: {
                    HStack(spacing: LayoutMetrics.xSmall) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(AppPalette.textFaint)
                        Text("ADD PRODUCT")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(AppPalette.textFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LayoutMetrics.medium)
                }
                .buttonStyle(.plain)
            }
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
        }
    }

    private func productRow(entry: Binding<ProductWithShopLink>) -> some View {
        let product = entry.wrappedValue.product
        let hasShopURL = !entry.wrappedValue.shopURL.trimmingCharacters(in: .whitespaces).isEmpty

        return VStack(spacing: 0) {
            HStack(spacing: LayoutMetrics.xSmall) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(white: 0.96))
                    AsyncImage(url: URL(string: product.image)) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFit().padding(4)
                        } else { Color.clear }
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppPalette.textPrimary)
                        .lineLimit(1)
                    if !hasShopURL {
                        Text("Add a shop link to show on feed")
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.textFaint)
                    } else {
                        Text(entry.wrappedValue.shopURL)
                            .font(.system(size: 10))
                            .foregroundStyle(AppPalette.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    withAnimation { taggedProducts.removeAll { $0.id == entry.wrappedValue.id } }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppPalette.textFaint)
                        .frame(width: 28, height: 28)
                        .background(AppPalette.groupedBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(LayoutMetrics.medium)

            // Shop link — available to everyone
            // Products without a link won't appear on the public feed card
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(hasShopURL ? AppPalette.textSecondary : AppPalette.textFaint)
                TextField("", text: entry.shopURL, prompt:
                    Text("Add shop link to show on feed")
                        .foregroundColor(AppPalette.textFaint)
                )
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            }
            .padding(.horizontal, LayoutMetrics.medium)
            .padding(.bottom, LayoutMetrics.xSmall)
        }
    }

    // MARK: - Pro note

    private var feedNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textFaint)
            Text("Only products with a shop link will appear on your public feed card.")
                .font(.system(size: 11))
                .foregroundStyle(AppPalette.textFaint)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Publish

    private var publishButton: some View {
        Button {
            Task { await publish() }
        } label: {
            Group {
                if isPublishing {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text("PUBLISH")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(AppPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.bottom, LayoutMetrics.xLarge)
        }
        .buttonStyle(.plain)
        .disabled(isPublishing)
        .background(AppPalette.groupedBackground.ignoresSafeArea())
    }

    private func publish() async {
        isPublishing = true
        // Build product inputs: for pro users, only include products with shop URL on the public card
        let inputs = taggedProducts.map { entry in
            ProductInput(
                outfitId: outfit.id,
                name: entry.product.name,
                price: nil,
                image: entry.product.image,
                shopLink: entry.shopURL.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : entry.shopURL.trimmingCharacters(in: .whitespaces)
            )
        }
        do {
            guard let userId = store.userId else { throw PublishError.notAuthenticated }
            try await OutfitService.publishOutfit(
                outfitId: outfit.id,
                caption: caption.isEmpty ? nil : caption,
                products: inputs,
                outfit: outfit,
                userId: userId
            )
            let updatedProducts = taggedProducts.map { entry -> Product in
                var p = entry.product
                let url = entry.shopURL.trimmingCharacters(in: .whitespaces)
                p.shopLink = url.isEmpty ? nil : url
                return p
            }
            await MainActor.run {
                onPublished(caption.isEmpty ? nil : caption, updatedProducts)
                dismiss()
            }
        } catch {
            await MainActor.run { publishError = error.localizedDescription; isPublishing = false }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
    }
}

private enum PublishError: LocalizedError {
    case notAuthenticated
    var errorDescription: String? { "You must be signed in to publish." }
}

// MARK: - Helper

private struct ProductWithShopLink: Identifiable {
    let id = UUID()
    let product: Product
    var shopURL: String
}
