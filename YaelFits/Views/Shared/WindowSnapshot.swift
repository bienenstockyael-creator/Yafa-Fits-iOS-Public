import UIKit

/// Captures the current screen as a UIImage by rendering the
/// key window's view hierarchy. Unlike SwiftUI's
/// `ImageRenderer` or `.layerEffect` flattening, this DOES
/// include `UIViewRepresentable` content — `LightBlurView`,
/// `LottieAnimationView`, etc — because it goes through
/// UIKit's `drawHierarchy(in:afterScreenUpdates:)` which knows
/// how to rasterize any UIView subclass.
///
/// Used by the vibes wave shader: at tap time we snapshot the
/// screen, then a Metal shader distorts that static bitmap
/// while it overlays the live UI. The live UI keeps animating
/// underneath; the user just doesn't see those updates until
/// the snapshot fades out at the end of the burst.
enum WindowSnapshot {
    /// Render the foreground-active key window into a UIImage.
    /// Returns nil only if no foreground window exists (e.g.
    /// during app backgrounding transitions).
    @MainActor
    static func capture() -> UIImage? {
        guard let window = activeKeyWindow() else { return nil }
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        // Use the screen's native scale (e.g. 3x on Pro models)
        // so the snapshot is pixel-accurate to the live UI.
        format.scale = window.screen.scale
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        return renderer.image { _ in
            // `afterScreenUpdates: true` — wait for SwiftUI's
            // pending render to commit before snapshotting. The
            // vibe button's morph-fade opacity change is set
            // synchronously when the tap fires; without
            // `afterScreenUpdates: true`, the snapshot would
            // capture the pre-fade frame (button still visible),
            // and the user would see a static "ghost" button in
            // the snapshot for the wave shader's whole lifetime.
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    private static func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)
    }
}
