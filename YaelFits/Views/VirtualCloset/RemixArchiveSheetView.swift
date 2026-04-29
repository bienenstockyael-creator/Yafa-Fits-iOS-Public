import SwiftUI
import UIKit

/// Grid of saved remixes (dressed-avatar generations). Reached via a button
/// in the Virtual Closet header so the rest of the app stays uncluttered —
/// remixes are a closet-internal concept, not a top-level tab.
struct RemixArchiveSheetView: View {
    var onClose: () -> Void

    @State private var remixes: [Remix] = []
    @State private var isLoading = true

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: LayoutMetrics.small),
        GridItem(.flexible(), spacing: LayoutMetrics.small),
    ]

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .task { await loadRemixes() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                AppIcon(glyph: .xmark, size: 14, color: AppPalette.iconPrimary)
                    .frame(width: 36, height: 36)
                    .appCircle(shadowRadius: 0, shadowY: 0)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("REMIXES")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, LayoutMetrics.screenPadding)
        .padding(.top, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView().tint(AppPalette.textFaint)
            Spacer()
        } else if remixes.isEmpty {
            Spacer()
            emptyState
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: LayoutMetrics.small) {
                    ForEach(remixes) { remix in
                        RemixCell(remix: remix, onDelete: { delete(remix) })
                    }
                }
                .padding(.horizontal, LayoutMetrics.screenPadding)
                .padding(.top, LayoutMetrics.medium)
                .padding(.bottom, LayoutMetrics.large)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: LayoutMetrics.small) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 28))
                .foregroundStyle(AppPalette.textFaint.opacity(0.6))
            Text("NO REMIXES YET")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(AppPalette.textFaint)
            Text("Save dressed looks in the closet to archive them here.")
                .font(.system(size: 12))
                .foregroundStyle(AppPalette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, LayoutMetrics.large)
        }
    }

    // MARK: - Loading / mutation

    private func loadRemixes() async {
        let loaded = (try? RemixStorage.loadAll()) ?? []
        await MainActor.run {
            remixes = loaded
            isLoading = false
        }
    }

    private func delete(_ remix: Remix) {
        try? RemixStorage.delete(remix)
        remixes.removeAll { $0.id == remix.id }
    }
}

// MARK: - Cell

private struct RemixCell: View {
    let remix: Remix
    var onDelete: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(Color.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                ProgressView().tint(AppPalette.textFaint)
            }
        }
        .aspectRatio(0.7, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: LayoutMetrics.cardCornerRadius, style: .continuous))
        .contextMenu {
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .task(id: remix.id) {
            image = RemixStorage.loadImage(for: remix)
        }
    }
}
