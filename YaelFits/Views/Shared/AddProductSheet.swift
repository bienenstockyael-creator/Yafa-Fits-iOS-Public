import PhotosUI
import SwiftUI

/// Presented when adding a product to an outfit.
/// Two modes: create a new product, or pick one from the library.
struct AddProductSheet: View {
    let userId: UUID
    let outfitId: String
    var onAdded: (ProductLibraryItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .create

    enum Mode { case create, library }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .create:  CreateProductView(userId: userId, outfitId: outfitId, onAdded: finish)
                case .library: LibraryPickerView(userId: userId, outfitId: outfitId, onAdded: finish)
                }
            }
            .background(AppPalette.groupedBackground)
            .navigationTitle(mode == .create ? "New Product" : "Your Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppPalette.textMuted)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(mode == .create ? "Library" : "New") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            mode = mode == .create ? .library : .create
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppPalette.textSecondary)
                }
            }
        }
    }

    private func finish(_ item: ProductLibraryItem) {
        onAdded(item)
        dismiss()
    }
}

// MARK: - Create new product

private struct CreateProductView: View {
    let userId: UUID
    let outfitId: String
    var onAdded: (ProductLibraryItem) -> Void

    @State private var name = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var processedImageURL: String?
    @State private var processingStatus: String?
    @State private var processingError: String?
    @State private var processingTask: Task<Void, Never>?

    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: LayoutMetrics.medium) {
                    imageSection
                    nameSection
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.medium)
            }
            .scrollDismissesKeyboard(.interactively)

            saveButton
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadAndProcess(item) }
        }
        .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    // MARK: Image

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            sectionLabel("PRODUCT PHOTO")

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                ZStack {
                    if let img = selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 160)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppPalette.pageBackground)
                            .frame(height: 160)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(AppPalette.cardBorder, lineWidth: 1)
                            )
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(AppPalette.textFaint)
                                    Text("Choose a photo")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(AppPalette.textMuted)
                                    Text("For best results, use a clean photo or\nscreenshot without people or hangers.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppPalette.textFaint)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 16)
                                }
                            }
                    }

                    // Processing overlay — spinner only, no distracting status text
                    if processingStatus != nil {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.4))
                            .frame(height: 160)
                        ProgressView().tint(.white).scaleEffect(1.2)
                    }

                    // Done checkmark
                    if processedImageURL != nil && processingStatus == nil {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .background(Color.green.clipShape(Circle()))
                                    .padding(8)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if let err = processingError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
            }
        }
    }

    // MARK: Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.xxSmall) {
            sectionLabel("PRODUCT NAME")
            TextField("", text: $name, prompt:
                Text("e.g. Wide Leg Jeans")
                    .foregroundColor(AppPalette.textSecondary)
            )
            .font(.system(size: 14))
            .foregroundStyle(AppPalette.textPrimary)
            .padding(LayoutMetrics.xSmall)
            .background(AppPalette.pageBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppPalette.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: Save

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(AppPalette.textMuted)
                } else {
                    Text("SAVE PRODUCT")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(canSave ? AppPalette.textPrimary : AppPalette.textFaint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .appCard(cornerRadius: LayoutMetrics.cardCornerRadius)
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.vertical, LayoutMetrics.xSmall)
        }
        .buttonStyle(.plain)
        .disabled(!canSave || isSaving)
        .background(AppPalette.groupedBackground)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && processedImageURL != nil
    }

    // MARK: Logic

    private func loadAndProcess(_ item: PhotosPickerItem) async {
        // Cancel any in-flight upload before starting a new one
        processingTask?.cancel()
        processingTask = nil

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        await MainActor.run { selectedImage = image; processedImageURL = nil; processingError = nil }

        processingTask = Task {
            do {
                let url = try await ProductImageService.processAndUpload(
                    imageData: data,
                    userId: userId,
                    productName: name.isEmpty ? "product" : name,
                    onStatus: { status in
                        await MainActor.run { processingStatus = status }
                    }
                )
                await MainActor.run { processedImageURL = url; processingStatus = nil }
            } catch {
                await MainActor.run { processingError = error.localizedDescription; processingStatus = nil }
            }
        }
    }

    private func save() async {
        guard let imageURL = processedImageURL else { return }
        isSaving = true
        do {
            let item = try await ProductLibraryService.createProduct(
                userId: userId,
                name: name.trimmingCharacters(in: .whitespaces),
                imageURL: imageURL,
                tags: []
            )
            // Retry tagging once — product is created, we must not orphan it
            do {
                try await ProductLibraryService.tagOutfit(outfitId: outfitId, productId: item.id)
            } catch {
                try await ProductLibraryService.tagOutfit(outfitId: outfitId, productId: item.id)
            }
            await MainActor.run { onAdded(item) }
        } catch {
            await MainActor.run { saveError = error.localizedDescription; isSaving = false }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(AppPalette.textFaint)
    }
}

// MARK: - Pick from library

private struct LibraryPickerView: View {
    let userId: UUID
    let outfitId: String
    var onAdded: (ProductLibraryItem) -> Void

    @State private var products: [ProductLibraryItem] = []
    @State private var isLoading = true
    @State private var search = ""

    private var filtered: [ProductLibraryItem] {
        guard !search.isEmpty else { return products }
        let q = search.lowercased()
        return products.filter {
            $0.name.lowercased().contains(q) ||
            $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppPalette.textFaint)
                TextField("Search products…", text: $search)
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textPrimary)
            }
            .padding(LayoutMetrics.xSmall)
            .background(AppPalette.groupedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, LayoutMetrics.screenPadding)
            .padding(.vertical, LayoutMetrics.xSmall)

            if isLoading {
                Spacer()
                ProgressView().tint(AppPalette.textMuted)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text(products.isEmpty ? "No products yet" : "No results")
                    .font(.system(size: 14))
                    .foregroundStyle(AppPalette.textFaint)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { product in
                            Button {
                                Task {
                                    try? await ProductLibraryService.tagOutfit(
                                        outfitId: outfitId,
                                        productId: product.id
                                    )
                                    onAdded(product)
                                }
                            } label: {
                                libraryRow(product)
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.5).padding(.leading, 72)
                        }
                    }
                    .padding(.horizontal, LayoutMetrics.screenPadding)
                }
            }
        }
        .task { await load() }
    }

    private func libraryRow(_ product: ProductLibraryItem) -> some View {
        HStack(spacing: LayoutMetrics.xSmall) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.96))
                AsyncImage(url: URL(string: product.imageURL)) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFit().padding(4)
                    } else {
                        Color.clear
                    }
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(product.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppPalette.textPrimary)
                if !product.tags.isEmpty {
                    Text(product.tags.prefix(3).joined(separator: " · ").uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(AppPalette.textFaint)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(AppPalette.textFaint)
        }
        .padding(.vertical, LayoutMetrics.xSmall)
    }

    private func load() async {
        do {
            let items = try await ProductLibraryService.fetchProducts(userId: userId)
            await MainActor.run { products = items; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}
