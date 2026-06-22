import SwiftUI

struct AvatarCropView: View {
    let image: UIImage
    /// Returns two renders of the SAME framing (scale + offset):
    ///   - `circleCrop`: oval-clipped, for the round avatar.
    ///   - `squareCrop`: un-clipped square, used as the source for
    ///     bust background-removal so the cutout keeps the user's
    ///     centering and zoom (the circle's corners — exactly the
    ///     shoulders/hair a bust needs — survive here).
    let onConfirm: (_ circleCrop: UIImage, _ squareCrop: UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1.0

    private let cropSize: CGFloat = 280

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                cropArea
                Spacer()
                bottomHint
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button("Done") { cropAndConfirm() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 24)
    }

    private var cropArea: some View {
        ZStack {
            // The image, scaled and offset
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: cropSize, height: cropSize)
                .scaleEffect(scale * pinchScale)
                .offset(CGSize(
                    width: offset.width + dragOffset.width,
                    height: offset.height + dragOffset.height
                ))
                .clipShape(Circle())
                .gesture(drag)
                .gesture(pinch)

            // Circle border overlay
            Circle()
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: cropSize, height: cropSize)
                .allowsHitTesting(false)
        }
    }

    private var bottomHint: some View {
        Text("Drag and pinch to adjust")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.bottom, 40)
    }

    private var drag: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .updating($pinchScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                scale = max(1.0, min(scale * value.magnification, 5.0))
            }
    }

    private func cropAndConfirm() {
        let outputSize: CGFloat = 400
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSize, height: outputSize))

        // Shared framing math — identical scale + offset for both
        // renders so the square crop and the circle avatar stay in
        // perfect register (same pixels, the circle just clips the
        // corners away).
        let imageAspect = image.size.width / image.size.height
        let drawW: CGFloat
        let drawH: CGFloat
        if imageAspect > 1 {
            drawH = outputSize * scale
            drawW = drawH * imageAspect
        } else {
            drawW = outputSize * scale
            drawH = drawW / imageAspect
        }
        let normalizedOffsetX = offset.width / cropSize * outputSize
        let normalizedOffsetY = offset.height / cropSize * outputSize
        let drawRect = CGRect(
            x: (outputSize - drawW) / 2 + normalizedOffsetX,
            y: (outputSize - drawH) / 2 + normalizedOffsetY,
            width: drawW,
            height: drawH
        )

        // Square crop — same framing, NO oval clip. Bust
        // background-removal runs on this so the cutout preserves
        // the user's centering + zoom out to the corners.
        let squareCrop = renderer.image { _ in
            image.draw(in: drawRect)
        }

        // Circle crop — oval-clipped, for the round avatar.
        let circleCrop = renderer.image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: outputSize, height: outputSize)).addClip()
            image.draw(in: drawRect)
        }

        onConfirm(circleCrop, squareCrop)
    }
}
