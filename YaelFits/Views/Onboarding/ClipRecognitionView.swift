import SwiftUI

/// First screen a clip-installed user sees in the full app, BEFORE
/// sign-up: the fit that brought them here, spinning, with the
/// creator's name — "you're in the right place" recognition rather
/// than a cold auth form. Continue → AuthView (which carries the
/// pre-checked Follow row).
struct ClipRecognitionView: View {
    let handoff: ClipHandoff
    var onContinue: () -> Void

    @State private var outfit: Outfit?

    var body: some View {
        ZStack {
            AppPalette.groupedBackground.ignoresSafeArea()

            VStack(spacing: LayoutMetrics.small) {
                Spacer(minLength: LayoutMetrics.large)

                AvatarView(
                    url: handoff.creatorAvatarURL,
                    initial: String(handoff.creatorUsername.prefix(1)).uppercased(),
                    size: 56,
                    shadowRadius: 6,
                    shadowY: 2
                )

                Text("@\(handoff.creatorUsername) shared this fit with you")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppPalette.textStrong)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LayoutMetrics.large)

                Text("SPIN IT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(AppPalette.textFaint)

                // The shared fit, live and scrubbable — the same
                // component the feed renders.
                ZStack {
                    if let outfit {
                        RotatableOutfitImage(
                            outfit: outfit,
                            height: 380,
                            draggable: true,
                            eagerLoad: true
                        )
                    } else {
                        ProgressView()
                            .tint(AppPalette.textMuted)
                    }
                }
                .frame(height: 380)
                .frame(maxWidth: .infinity)

                Spacer(minLength: LayoutMetrics.small)

                Button(action: onContinue) {
                    Text("CONTINUE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(AppPalette.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .appCapsule(shadowRadius: 8, shadowY: 3)
                }
                .buttonStyle(SolidPressButtonStyle())
                .padding(.horizontal, LayoutMetrics.screenPadding)

                Text("Yafa is invite-only — you'll need a code to join.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppPalette.textFaint)
                    .padding(.bottom, LayoutMetrics.medium)
            }
        }
        .task {
            outfit = await ContentSource.getPublicOutfitsByIds([handoff.outfitId])
                .first?.outfit
        }
    }
}
