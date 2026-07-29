import SwiftUI
import StoreKit

// The clip's one screen: the feed card, expanded and shoppable, with
// the App Store overlay pinned at the bottom offering the full app.
struct ClipFitView: View {
    @Bindable var model: ClipModel
    @State private var showOverlay = false

    private let groupedBG = Color(red: 231 / 255, green: 232 / 255, blue: 236 / 255)

    var body: some View {
        ZStack {
            groupedBG.ignoresSafeArea()

            switch model.phase {
            case .loading:
                ProgressView()
                    .tint(Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255))
            case .unavailable:
                Text("THIS FIT ISN’T AVAILABLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255))
            case .ready:
                if let fit = model.fit {
                    ScrollView {
                        FitCard(fit: fit)
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 160) // clear the overlay
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .ready else { return }
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                showOverlay = true
            }
        }
        .appStoreOverlay(isPresented: $showOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }
}

private struct FitCard: View {
    let fit: ClipFit
    @Environment(\.openURL) private var openURL

    private let textStrong = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)
    private let textSecondary = Color(red: 75 / 255, green: 85 / 255, blue: 99 / 255)
    private let textMuted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    private let textFaint = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
                .padding(.bottom, 0)

            FrameSpinner(fit: fit)
                .frame(height: 400)
                .frame(maxWidth: .infinity)
                .scaleEffect(1.35)
                .clipped()

            VStack(alignment: .leading, spacing: 14) {
                if let caption = fit.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                socialRow
                if !fit.products.isEmpty {
                    productRow
                }
            }
            .padding(16)
            .padding(.top, 8)
        }
        .background(.white.opacity(0.4))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AsyncImage(url: fit.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.white.opacity(0.5))
                    .overlay(
                        Text(String(fit.username.prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(textMuted)
                    )
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(fit.username)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(textStrong)
                Text(fit.dateLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(textFaint)
            }

            Spacer()

            if let temp = fit.weatherTempC {
                HStack(spacing: 5) {
                    Image(systemName: weatherSymbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                    Text("\(temp)° C")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(textSecondary.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.45), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            }
        }
    }

    private var weatherSymbol: String {
        let c = (fit.weatherCondition ?? "").lowercased()
        if c.contains("sun") || c.contains("clear") { return "sun.max" }
        if c.contains("rain") { return "cloud.rain" }
        if c.contains("snow") { return "snowflake" }
        return "cloud"
    }

    private var socialRow: some View {
        HStack(spacing: 8) {
            socialChip(symbol: "heart", count: fit.likeCount)
            socialChip(symbol: "bubble.right", count: fit.commentCount)
            Spacer()
            Text("SHOP THE FIT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(textFaint)
        }
    }

    private func socialChip(symbol: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(textMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1))
    }

    private var productRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(fit.products) { product in
                    Button {
                        if let shop = product.shopURL {
                            openURL(shop)
                        }
                    } label: {
                        VStack(spacing: 6) {
                            AsyncImage(url: product.imageURL) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.white.opacity(0.35))
                            }
                            .frame(width: 56, height: 56)

                            Text("BUY")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(2.2)
                                .foregroundStyle(textMuted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.white.opacity(0.45), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.8))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
