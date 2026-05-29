import SwiftUI
import UIKit

/// Collapsed representation of the generation queue: 1 thumbnail
/// + status text at one job, more thumbnails as the queue grows
/// (capped at 3), and `+N` text once N > 3.
struct GenerationChipPill: View {
    let jobs: [PipelineJob]
    let queue: GenerationQueue
    /// Shared with the stack so the chip ↔ stack swap uses
    /// matched-geometry rather than a crossfade.
    let namespace: Namespace.ID
    /// In the single-job case, hide the chip while the card morph
    /// runs — the chip sits above the outer ZStack via
    /// `safeAreaInset` and would otherwise cover the morph origin.
    let isHostingExpandedCard: Bool
    let onTap: () -> Void

    private let thumbnailSize: CGFloat = 28
    private let thumbnailOverlap: CGFloat = 10
    private let maxVisibleThumbnails: Int = 3

    private var visibleJobs: [PipelineJob] {
        Array(jobs.suffix(maxVisibleThumbnails))
    }

    private var hiddenCount: Int {
        max(0, jobs.count - maxVisibleThumbnails)
    }

    private var trailingText: String {
        if hiddenCount > 0 {
            return "+\(hiddenCount)"
        } else if let mostRecent = jobs.last {
            return queue.phase(for: mostRecent).pillText
        } else {
            return ""
        }
    }

    private var trailingTextColor: Color {
        hiddenCount > 0 ? AppPalette.textPrimary : AppPalette.textSecondary
    }

    private var anyJobNeedsUserAction: Bool {
        jobs.contains { queue.phase(for: $0).needsUserAction }
    }

    /// Multi-job case keeps the chip visible behind the card as a
    /// queue indicator + tap-to-dismiss target.
    private var shouldHideForMorph: Bool {
        isHostingExpandedCard && jobs.count == 1
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                thumbnails
                if !trailingText.isEmpty {
                    Text(trailingText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trailingTextColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        // Crossfade so the swap between status
                        // text ("Cooking your fit") and "+1" at
                        // the 3 → 4 threshold isn't a hard cut.
                        .id(trailingText)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            // 1–3 pills: match the stack's fixed pill width so the
            // chip ↔ stack morph hands off cleanly. 4+ pills: drop
            // the floor so the chip hugs its short "+N" text.
            .frame(
                minWidth: jobs.count >= 4 ? 0 : GenerationLayout.pillWidth,
                minHeight: GenerationLayout.pillHeight
            )
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
            .shadow(color: Color.black.opacity(0.1), radius: 12, y: 6)
            // Soft glow halo when any job needs the user's input.
            .shadow(
                color: AppPalette.uploadGlow.opacity(anyJobNeedsUserAction ? 0.3 : 0),
                radius: 20,
                y: 0
            )
            .animation(.easeInOut(duration: 0.4), value: anyJobNeedsUserAction)
            // Pairs with the bottom pill of `GenerationPillStack`
            // so chip ↔ stack morphs frame instead of crossfading.
            .matchedGeometryEffect(id: "compact-pill", in: namespace)
            // `.animation(nil)` so the hide snap doesn't ride any
            // ambient animation curve — chip and card pill content
            // are identical, so an instant swap is invisible.
            .opacity(shouldHideForMorph ? 0 : 1)
            .animation(nil, value: shouldHideForMorph)
        }
        .buttonStyle(SolidPressButtonStyle())
        // Animates thumb insertions/removals and the status ↔ "+N"
        // text swap. Keyed on job ids so SwiftUI runs the right
        // `.transition` on the specific thumbnail that came/went.
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: jobs.map(\.id))
    }

    /// Most-recent N thumbnails, overlapping. Last in the array
    /// (newest) renders rightmost on top.
    private var thumbnails: some View {
        HStack(spacing: -thumbnailOverlap) {
            ForEach(Array(visibleJobs.enumerated()), id: \.element.id) { idx, job in
                thumbnail(for: job)
                    .zIndex(Double(idx))
                    // New thumbs scale up from the center; old
                    // ones (when crossing the 3-thumb cap) scale
                    // back down. Combined with .opacity so the
                    // appearance is a soft pop rather than an
                    // abrupt insert.
                    .transition(.scale.combined(with: .opacity))
                    // Pair with the corresponding pill's thumbnail
                    // in `GenerationPillStack` via the shared
                    // namespace. When transitioning stack →
                    // chip, each pill's thumbnail flies to its
                    // slot in the chip (and vice versa on
                    // expand).
                    .matchedGeometryEffect(id: "thumb-\(job.id)", in: namespace)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for job: PipelineJob) -> some View {
        CachedJobThumbnail(sourceImage: job.sourceImage, size: thumbnailSize)
            .clipShape(Circle())
    }
}

/// Thumbnail that decodes the source `Data` to `UIImage` once
/// (off-main, on `.userInitiated`) and caches the result in
/// `@State`. The naive `UIImage(data:)`-in-body version re-decoded
/// a full-res JPEG on every SwiftUI render — visible lag when
/// multiple pills were on screen.
struct CachedJobThumbnail: View {
    let sourceImage: Data?
    let size: CGFloat

    @State private var cachedImage: UIImage?

    var body: some View {
        Group {
            if let image = cachedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size, alignment: .center)
                    .clipped()
            } else {
                AppPalette.groupedBackground
                    .frame(width: size, height: size)
            }
        }
        .task(id: sourceImage) {
            // Decode off the main thread so frame budget isn't
            // burned on JPEG parsing — then hop back to apply.
            guard let data = sourceImage else {
                cachedImage = nil
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            cachedImage = decoded
        }
    }
}
