import SwiftUI
import UIKit

/// Vertical stack of in-flight generation pills above the tab bar.
/// Newest pill at the bottom (closest to the tab bar that spawned
/// it); active jobs precede waiting jobs in the array.
struct GenerationPillStack: View {
    let queue: GenerationQueue
    /// Job whose expanded card is currently on screen. The matching
    /// pill stays in layout (opacity 0) so the card's collapse-
    /// morph has a stable anchor target.
    let expandedJobId: String?
    /// When true, pills above the expanded slot shift down by one
    /// slot so the stack compacts toward the expanded pill.
    let isCardExpanded: Bool
    /// Shared with `GenerationChipPill` for matched-geometry on the
    /// bottom-pill ↔ chip anchor and per-thumbnail morphs.
    let namespace: Namespace.ID
    let onPillTapped: (PipelineJob) -> Void

    private let slotHeight: CGFloat = GenerationLayout.pillHeight + GenerationLayout.pillVerticalSpacing

    var body: some View {
        let allJobs = queue.activeJobs + queue.waitingJobs
        let expandedIdx: Int? = expandedJobId.flatMap { id in
            allJobs.firstIndex(where: { $0.id == id })
        }

        VStack(spacing: GenerationLayout.pillVerticalSpacing) {
            ForEach(Array(allJobs.enumerated()), id: \.element.id) { idx, job in
                // Last pill = visual bottom of stack = same Y as
                // the chip. It claims the `compact-pill` matched-
                // geometry id so chip ↔ stack morphs the frame
                // rather than crossfading.
                let isBottom = (idx == allJobs.count - 1)
                GenerationPill(
                    job: job,
                    phase: queue.phase(for: job),
                    isExpanded: expandedJobId == job.id,
                    namespace: namespace,
                    isCompactPillAnchor: isBottom
                ) {
                    onPillTapped(job)
                }
                .opacity(expandedJobId == job.id ? 0 : 1)
                .offset(y: yOffset(for: job, in: allJobs, expandedIdx: expandedIdx))
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    // Soft shrink-and-fade on removal — no hard cut
                    // when a job completes or is cancelled.
                    removal: .scale(scale: 0.6).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: queue.activeJobs.map(\.id))
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: queue.waitingJobs.map(\.id))
        .padding(.horizontal, LayoutMetrics.medium)
    }

    /// Per-pill vertical offset. Pills above the expanded slot
    /// (earlier in the array) shift down by one slot when the
    /// card is expanded. Everything else stays at offset 0.
    private func yOffset(for job: PipelineJob, in jobs: [PipelineJob], expandedIdx: Int?) -> CGFloat {
        guard isCardExpanded,
              let eIdx = expandedIdx,
              let myIdx = jobs.firstIndex(where: { $0.id == job.id }),
              myIdx < eIdx else {
            return 0
        }
        return slotHeight
    }
}

/// Single pill: thumbnail + status text. Pulses once on entry to a
/// needs-attention phase. Bottom pill in the stack is the matched-
/// geometry anchor that pairs with `GenerationChipPill`.
struct GenerationPill: View {
    let job: PipelineJob
    let phase: GenerationPhase
    /// When true, the expanded card is showing — pill content snaps
    /// invisible so the card's morph isn't drawing both layers.
    let isExpanded: Bool
    let namespace: Namespace.ID
    /// `true` for the bottom pill — claims the `compact-pill`
    /// matched-geometry id that pairs with the chip.
    let isCompactPillAnchor: Bool
    let onTap: () -> Void

    /// True for one beat after `phase` flips into a needs-attention
    /// state. Drives the pulse.
    @State private var isCallingAttention = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                thumbnail
                Text(phase.pillText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppPalette.textSecondary)
                    .lineLimit(1)
                    // `fixedSize` so the text stays at its natural
                    // width — otherwise it'd truncate at intermediate
                    // pill widths during matched-geometry morphs.
                    .fixedSize(horizontal: true, vertical: false)
                // Notification dot — glows the same color as the
                // sparkle field. Only when the pill is review-ready.
                if phase == .readyToReview {
                    Circle()
                        .fill(AppPalette.uploadGlow)
                        .frame(width: 7, height: 7)
                        .shadow(color: AppPalette.uploadGlow.opacity(0.7), radius: 4, y: 0)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            // `.animation(nil)` so the content's hide snap doesn't
            // drag through the morph curve — chip + card pill
            // content are identical so an instant swap is invisible.
            .opacity(isExpanded ? 0 : 1)
            .animation(nil, value: isExpanded)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(width: GenerationLayout.pillWidth)
            .frame(minHeight: GenerationLayout.pillHeight)
            .background {
                ZStack {
                    LightBlurView(style: .systemThinMaterialLight)
                        .clipShape(RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous))
                    RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous)
                        .fill(AppPalette.cardFill)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: GenerationLayout.cornerRadius, style: .continuous)
                    .strokeBorder(AppPalette.cardBorder, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
            // Aqua halo only when the pill needs user attention.
            // Conditionally apply the shadow modifier rather than
            // always rendering one with opacity 0 — keeps the
            // shadow off the GPU when it has no visible effect.
            .shadow(
                color: phase.needsUserAction ? AppPalette.uploadGlow.opacity(0.3) : .clear,
                radius: phase.needsUserAction ? 16 : 0,
                y: 0
            )
            .animation(.easeInOut(duration: 0.4), value: phase.needsUserAction)
            .scaleEffect(isCallingAttention ? 1.06 : 1.0)
            // Only the bottom pill claims the `compact-pill` id;
            // others use distinct ids so they don't conflict with
            // the single chip anchor.
            .matchedGeometryEffect(
                id: isCompactPillAnchor ? "compact-pill" : "compact-pill-passive-\(job.id)",
                in: namespace
            )
        }
        .buttonStyle(SolidPressButtonStyle())
        .onChange(of: phase.needsUserAction) { _, needs in
            guard needs else { return }
            // One-shot pulse: spring up, spring back.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) {
                isCallingAttention = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    isCallingAttention = false
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        CachedJobThumbnail(sourceImage: job.sourceImage, size: 28)
            .clipShape(Circle())
            // Pairs with the same-id thumbnail in `GenerationChipPill`
            // — chip ↔ stack flies the thumbs between slots.
            .matchedGeometryEffect(id: "thumb-\(job.id)", in: namespace)
    }
}

