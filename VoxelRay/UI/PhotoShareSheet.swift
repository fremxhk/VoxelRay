import SwiftUI
import UIKit

/// Presents the native iOS share sheet for Photo Mode renders.
public struct PhotoShareSheet: UIViewControllerRepresentable {
    public let image: UIImage
    public let onDismiss: () -> Void

    public init(image: UIImage, onDismiss: @escaping () -> Void) {
        self.image = image
        self.onDismiss = onDismiss
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                onDismiss()
            }
        }
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
