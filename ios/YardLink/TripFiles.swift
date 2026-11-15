import SwiftUI
import UIKit

extension UIImage {
    /// The photo as a `data:image/jpeg;base64,…` address, scaled down so it
    /// uploads quickly on a weak signal. This is the form the server takes.
    func jpegDataUrl(maxDimension: CGFloat, quality: CGFloat = 0.8) -> String? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: quality) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }
}

/// What a photo or document is filed against. A file on a trip is also
/// filed on that trip's container and chassis by the server.
enum FileScope {
    case trip(String)
    case container(String)

    var query: [String: String] {
        switch self {
        case .trip(let id): return ["tripId": id]
        case .container(let id): return ["containerId": id]
        }
    }
}

/// Photos and paperwork kept on the employer's server, where the driver's
/// phone, the web app and dispatch all see the same files.
enum TripFiles {
    private struct UploadBody: Encodable {
        let dataUrl: String
        let fileName: String
        let category: String
        let tripId: String?
        let containerId: String?
    }

    /// Save a photo and answer the new document's id.
    @discardableResult
    static func upload(_ image: UIImage, named fileName: String, to scope: FileScope, api: APIClient?) async throws -> String {
        guard let api, let dataUrl = image.jpegDataUrl(maxDimension: 2000) else {
            throw APIError(status: 0, message: "The photo could not be prepared. Try taking it again.", flags: [:])
        }
        let saved: DocumentEnvelope = try await api.post(
            "/api/documents",
            body: UploadBody(
                dataUrl: dataUrl,
                fileName: fileName,
                category: "PHOTO",
                tripId: scope.query["tripId"],
                containerId: scope.query["containerId"]
            ),
            patient: true
        )
        return saved.document.id
    }

    static func list(_ scope: FileScope, api: APIClient) async throws -> [DocumentItem] {
        let list: DocumentList = try await api.get("/api/documents", query: scope.query)
        return list.items
    }
}

/// The system camera, for one photo. Falls back to the photo library where
/// there is no camera (the simulator).
struct CameraCapture: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraCapture

        init(_ parent: CameraCapture) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// A picture stored on the server, loaded with the signed-in session.
struct ServerImage: View {
    @EnvironmentObject private var model: AppModel
    let documentId: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Brand.mist
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").foregroundColor(Brand.muted)
            } else {
                ProgressView()
            }
        }
        .task(id: documentId) {
            guard image == nil, let api = model.api else { return }
            if let data = try? await api.data("/api/documents/\(documentId)/file"), let loaded = UIImage(data: data) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}
