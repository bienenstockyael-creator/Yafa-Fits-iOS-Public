import SwiftUI
import PhotosUI
import UIKit

/// Two floating squares that hover above the tab bar when the user
/// taps the upload icon. The picker sits *over* the current view
/// (archive or feed) so the user keeps spatial context with their
/// grid while they pick a photo. On selection, the picker dismisses
/// and the caller enqueues a job (`OutfitStore.generationQueue.enqueue`).
///
/// The squares themselves keep the same icon + label vocabulary the
/// upload step used (Camera Roll / Camera) so users who learned the
/// old flow recognize the controls.
struct GenerationPicker: View {
    @Binding var isPresented: Bool
    /// Fired when the user finishes picking — never called with nil
    /// (cancel paths just set `isPresented = false`). Receives the
    /// raw `UIImage` so the queue can normalize/encode it.
    let onImagePicked: (UIImage) -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var isLoadingFromLibrary = false

    /// Vertical gap between the squares and the tab bar. Small
    /// (6pt) so the squares feel anchored to the bar — visually
    /// "launched from" the upload icon, not floating in mid-air.
    private let liftAboveTabBar: CGFloat = 6

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tap-outside dismiss. Backdrop is a near-transparent
            // scrim so the user can still see the archive behind —
            // the picker is "lightweight" not "modal." Has its own
            // `.transition(.opacity)` so it fades independently
            // from the squares (which scale up from the bottom).
            // With a shared parent transition, the squares'
            // scale-from-bottom would visibly scale the backdrop
            // edges too.
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .transition(.opacity)

            HStack(spacing: LayoutMetrics.xxSmall) {
                PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                    pickerSquare(icon: .image, label: "Camera Roll")
                }
                .buttonStyle(SolidPressButtonStyle())
                .disabled(isLoadingFromLibrary)

                Button {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
                    showingCamera = true
                } label: {
                    pickerSquare(icon: .camera, label: "Camera")
                }
                .buttonStyle(SolidPressButtonStyle())
            }
            .padding(.horizontal, LayoutMetrics.small)
            .padding(.bottom, liftAboveTabBar)
            // Squares pop up from the tab bar (scale anchor .bottom)
            // on entry, fade out on exit. Separate transition from
            // the backdrop so the backdrop only fades.
            .transition(.asymmetric(
                insertion: .scale(scale: 0.6, anchor: .bottom)
                    .combined(with: .opacity),
                removal: .opacity
            ))
        }
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            isLoadingFromLibrary = true
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        onImagePicked(uiImage)
                        dismiss()
                    }
                } else {
                    await MainActor.run {
                        isLoadingFromLibrary = false
                        selectedPhoto = nil
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            GenerationCameraCapture { image in
                showingCamera = false
                if let image {
                    onImagePicked(image)
                    dismiss()
                }
            }
            .ignoresSafeArea()
        }
    }

    private func dismiss() {
        // Snappier than present (higher damping, faster response) so
        // dismiss feels decisive — Apple's pattern: in-springy,
        // out-curt.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            isPresented = false
        }
    }

    /// Icon-in-circle + label, expanded to fill half the row width
    /// via `maxWidth: .infinity`, `minHeight: 132`.
    ///
    /// Drop shadow is layered (one wider/soft + one tight) to match
    /// the tab bar's elevation language — the squares read as "in
    /// the same layer" as the bar they sit above.
    private func pickerSquare(icon: AppIconGlyph, label: String) -> some View {
        VStack(spacing: LayoutMetrics.small) {
            AppIcon(glyph: icon, size: 24, color: AppPalette.iconPrimary)
                .frame(width: 52, height: 52)
                .appCircle(shadowRadius: 0, shadowY: 0)

            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(LayoutMetrics.medium)
        .appCard(cornerRadius: LayoutMetrics.cardCornerRadius, shadowRadius: 0, shadowY: 0)
        .shadow(color: Color.black.opacity(0.14), radius: 22, y: 12)
        .shadow(color: Color.black.opacity(0.06), radius: 6, y: 3)
    }
}

/// Thin wrapper around `UIImagePickerController` in `.camera` mode.
/// Pinned to rear camera, full-screen modal, native shutter UI.
struct GenerationCameraCapture: UIViewControllerRepresentable {
    let onImagePicked: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.modalPresentationStyle = .fullScreen
        picker.showsCameraControls = true
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImagePicked: (UIImage?) -> Void

        init(onImagePicked: @escaping (UIImage?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImagePicked(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImagePicked(nil)
        }
    }
}
