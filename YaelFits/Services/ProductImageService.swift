import UIKit

struct ProductImageService {

    /// Removes background from imageData, resizes to thumbnail, uploads to
    /// Supabase Storage `products` bucket. Returns the public URL string.
    static func processAndUpload(
        imageData: Data,
        userId: UUID,
        productName: String,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        // 1. Background removal via fal.ai
        let pngData = try await FalBackgroundRemovalService.shared.removeBackground(
            from: imageData,
            onUpdate: { progress in
                await onStatus(progress.title)
            }
        )

        // 2. Trim transparent edges then resize to thumbnail (max 600px)
        let thumbnailData: Data
        if let image = UIImage(data: pngData) {
            let trimmed = trimTransparentEdges(image)
            let resized = resize(trimmed, maxSide: 600) ?? trimmed
            thumbnailData = resized.pngData() ?? pngData
        } else {
            thumbnailData = pngData
        }

        await onStatus("Uploading product image…")

        // 3. Upload to Supabase Storage
        let safeName = productName
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let timestamp = Int(Date().timeIntervalSince1970)
        let filePath = "\(userId.uuidString)/\(safeName)-\(timestamp).png"

        try await supabase.storage
            .from("products")
            .upload(filePath, data: thumbnailData, options: .init(contentType: "image/png"))

        let publicURL = try supabase.storage
            .from("products")
            .getPublicURL(path: filePath)

        return publicURL.absoluteString
    }

    private static func resize(_ image: UIImage, maxSide: CGFloat) -> UIImage? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Crops transparent/alpha padding so the product fills the bounding box tightly.
    /// Without this, scaledToFit includes the empty alpha canvas, making products look tiny.
    static func trimTransparentEdges(_ image: UIImage, padding: Int = 6) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = 0, maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[y * bytesPerRow + x * bytesPerPixel + 3]
                if alpha > 8 { // ignore near-transparent noise
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard minX < maxX, minY < maxY else { return image }

        let cropRect = CGRect(
            x: max(0, minX - padding),
            y: max(0, minY - padding),
            width: min(width, maxX - minX + padding * 2 + 1),
            height: min(height, maxY - minY + padding * 2 + 1)
        )

        guard let cropped = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
