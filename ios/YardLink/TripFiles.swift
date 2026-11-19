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

/// What the driver is filing: it decides the name the file is saved under and
/// how the list is sorted, so paperwork is findable months later.
enum DocumentKind: String, CaseIterable, Identifiable {
    case equipmentPhoto = "PHOTO"
    case billOfLading = "BILL_OF_LADING"
    case eir = "EIR"
    case pod = "POD"
    case gateTicket = "GATE_TICKET"
    case scaleTicket = "SCALE_TICKET"
    case other = "OTHER"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .equipmentPhoto: return "Container / Chassis Image"
        case .billOfLading: return "Bill of Lading"
        case .eir: return "EIR / Interchange"
        case .pod: return "Proof of Delivery"
        case .gateTicket: return "Gate Ticket"
        case .scaleTicket: return "Scale Ticket"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .equipmentPhoto: return "shippingbox.fill"
        case .billOfLading, .eir, .pod, .gateTicket, .scaleTicket: return "doc.text.fill"
        case .other: return "paperclip"
        }
    }

    /// Paper forms photographed, as opposed to a photo of the equipment
    /// itself — these are what the server cleans up into a flat, evenly
    /// lit "scanned" look before storing. A container/chassis photo and an
    /// "Other" catch-all both stay the literal photo that was taken.
    var isPaperDocument: Bool {
        switch self {
        case .billOfLading, .eir, .pod, .gateTicket, .scaleTicket: return true
        case .equipmentPhoto, .other: return false
        }
    }

    /// The order the list puts them in: the equipment first, then paperwork.
    var rank: Int {
        switch self {
        case .equipmentPhoto: return 0
        case .billOfLading: return 1
        case .eir: return 2
        case .pod: return 3
        case .gateTicket: return 4
        case .scaleTicket: return 5
        case .other: return 6
        }
    }

    /// What a file of this kind is called. A container photo is simply
    /// "Container BSIU 863881-1", which is what the yard calls it too.
    func name(forContainer container: String?, chassis: String?) -> String {
        let equipment = [container, chassis].compactMap { $0 }.first { !$0.isEmpty }
        switch self {
        case .equipmentPhoto:
            guard let equipment else { return "Equipment photo" }
            return "\(container?.isEmpty == false ? "Container" : "Chassis") \(equipment)"
        case .billOfLading:
            return equipment.map { "Bill of Lading \($0)" } ?? "Bill of Lading"
        case .eir:
            return equipment.map { "EIR \($0)" } ?? "EIR"
        case .pod:
            return equipment.map { "Proof of Delivery \($0)" } ?? "Proof of Delivery"
        case .gateTicket:
            return equipment.map { "Gate Ticket \($0)" } ?? "Gate Ticket"
        case .scaleTicket:
            return equipment.map { "Scale Ticket \($0)" } ?? "Scale Ticket"
        case .other:
            return equipment.map { "Document \($0)" } ?? "Document"
        }
    }

    /// How the server labels a file that was not filed by this list.
    static func label(forCategory category: String?) -> String {
        guard let category else { return "Document" }
        if let known = DocumentKind(rawValue: category) { return known.label }
        switch category {
        case "DELIVERY_ORDER": return "Delivery order"
        case "DAMAGE_REPORT": return "Damage report"
        case "REPAIR_INVOICE": return "Repair invoice"
        case "CUSTOMS": return "Customs"
        default: return category.capitalized
        }
    }
}

/// A name no other file in the list has yet, so two bills of lading on one
/// container do not arrive with the same name.
func uniqueDocumentName(_ base: String, extension ext: String, taken: [String]) -> String {
    let used = Set(taken.map { $0.lowercased() })
    var candidate = "\(base).\(ext)"
    var counter = 2
    while used.contains(candidate.lowercased()) {
        candidate = "\(base) \(counter).\(ext)"
        counter += 1
    }
    return candidate
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
    static func upload(
        _ image: UIImage,
        named fileName: String,
        kind: DocumentKind = .equipmentPhoto,
        to scope: FileScope,
        api: APIClient?
    ) async throws -> String {
        guard let api, let dataUrl = image.jpegDataUrl(maxDimension: 2000) else {
            throw APIError(status: 0, message: "The photo could not be prepared. Try taking it again.", flags: [:])
        }
        let saved: DocumentEnvelope = try await api.post(
            "/api/documents",
            body: UploadBody(
                dataUrl: dataUrl,
                fileName: fileName,
                category: kind.rawValue,
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
