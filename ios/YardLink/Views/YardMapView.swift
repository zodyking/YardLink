import MapKit
import SwiftUI

/// The yard, seen from above: every container that has been placed, and a
/// way to place or move one. The web app draws the same thing on a canvas;
/// here it is the phone's own map, which a driver standing in the yard can
/// also see themselves on.
struct YardMapView: View {
    @EnvironmentObject private var model: AppModel
    let locationId: String
    let locationName: String
    let center: CLLocationCoordinate2D

    @State private var containers: [SiteContainer] = []
    @State private var region: MKCoordinateRegion
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var note: String?
    /// The container being placed. Nil while simply looking at the yard.
    @State private var placing: SiteContainer?
    @State private var rotation: Double = 0
    @State private var saving = false
    @State private var picking = false

    init(locationId: String, locationName: String, latitude: Double, longitude: Double) {
        self.locationId = locationId
        self.locationName = locationName
        center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            // About 150 m across: a yard fills the screen.
            span: MKCoordinateSpan(latitudeDelta: 0.0014, longitudeDelta: 0.0014)
        ))
    }

    /// Containers that have been put on the map.
    private var placed: [SiteContainer] {
        containers.filter { $0.latitude != nil && $0.longitude != nil }
    }

    private var unplaced: [SiteContainer] {
        containers.filter { $0.latitude == nil || $0.longitude == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Map(coordinateRegion: $region, annotationItems: placed) { box in
                    MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: box.latitude ?? 0, longitude: box.longitude ?? 0)) {
                        BoxMark(
                            number: box.number,
                            isLong: box.equipmentType == "DRY_40",
                            isLoaded: box.isLoaded ?? false,
                            rotation: box.rotation ?? 0,
                            dimmed: placing?.id == box.id
                        )
                        .onTapGesture { begin(placing: box) }
                    }
                }
                .ignoresSafeArea(edges: .horizontal)

                if placing != nil {
                    // A fixed crosshair: the driver moves the map under it,
                    // which is steadier than dragging a pin with a thumb.
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(Brand.navy)
                        .shadow(color: .white.opacity(0.9), radius: 3)
                        .allowsHitTesting(false)
                }

                if loading {
                    ProgressView().padding(12).background(.ultraThinMaterial, in: Circle())
                }
            }

            controls
        }
        .screenBackground()
        .navigationTitle("Yard")
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .sheet(isPresented: $picking) {
            PlacePickerSheet(containers: unplaced.isEmpty ? containers : unplaced) { box in
                begin(placing: box)
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage { ErrorBanner(message: errorMessage) }
            if let note { Banner(kind: .success, message: note) }

            if let placing {
                Text("Placing \(Marking.formatContainer(placing.number))")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.navy)
                Text("Move the map so the crosshair sits where the box is, then save.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)

                HStack(spacing: 10) {
                    Text("Angle")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.muted)
                    Slider(value: $rotation, in: 0...359, step: 5)
                        .tint(Brand.linkBlue)
                    Text("\(Int(rotation))°")
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundColor(Brand.navy)
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Button("Cancel") { self.placing = nil }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(saving)
                    Button(saving ? "Saving…" : "Save Spot") { Task { await save() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(saving)
                }
            } else {
                HStack {
                    Text("\(placed.count) placed")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.muted)
                    if !unplaced.isEmpty {
                        Text("· \(unplaced.count) not on the map")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Brand.warn)
                    }
                    Spacer()
                    Button {
                        region.center = center
                    } label: {
                        Image(systemName: "scope")
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Back to the yard")
                }
                Button("Place a Container") { picking = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(containers.isEmpty)
                Text("Tap a box on the map to move it.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.paper)
        .overlay(alignment: .top) { Rectangle().fill(Brand.line).frame(height: 1) }
    }

    private func begin(placing box: SiteContainer) {
        picking = false
        placing = box
        rotation = box.rotation ?? 0
        note = nil
        errorMessage = nil
        if let latitude = box.latitude, let longitude = box.longitude {
            region.center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let detail: LocationDetail = try await api.get("/api/locations/\(locationId)")
            containers = detail.containers ?? []
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private struct Request: Encodable {
        struct Spot: Encodable {
            let latitude: Double
            let longitude: Double
            let rotation: Double
        }

        let eventId: String
        let containerId: String
        let placement: Spot
    }

    private func save() async {
        guard let api = model.api, let box = placing else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let _: OkResult = try await api.post("/api/locations/\(locationId)/placements", body: Request(
                eventId: UUID().uuidString.lowercased(),
                containerId: box.id,
                placement: Request.Spot(
                    latitude: region.center.latitude,
                    longitude: region.center.longitude,
                    rotation: rotation
                )
            ))
            note = "\(Marking.formatContainer(box.number)) placed."
            placing = nil
            await load()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

/// A container drawn to scale and turned to its angle, with its number
/// alongside, as the yard view draws it on the web.
private struct BoxMark: View {
    let number: String
    let isLong: Bool
    let isLoaded: Bool
    let rotation: Double
    let dimmed: Bool

    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isLoaded ? Brand.navy : Brand.sky)
                .frame(width: isLong ? 44 : 24, height: 11)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).stroke(.white, lineWidth: 1))
                .rotationEffect(.degrees(rotation))
                .shadow(color: Brand.navy.opacity(0.3), radius: 2, y: 1)
            Text(Marking.formatContainer(number).suffix(5))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Brand.navy)
                .padding(.horizontal, 3)
                .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
        }
        .opacity(dimmed ? 0.35 : 1)
        .accessibilityLabel("Container \(number)")
    }
}

/// Which container to place.
private struct PlacePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let containers: [SiteContainer]
    let onPick: (SiteContainer) -> Void

    @State private var search = ""

    private var shown: [SiteContainer] {
        let needle = Marking.normalize(search)
        guard !needle.isEmpty else { return containers }
        return containers.filter { Marking.normalize($0.number).contains(needle) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SearchField(prompt: "Search containers", text: $search)
                    if shown.isEmpty {
                        EmptyNote(title: "Nothing to place", detail: "Containers on this location show up here.")
                    }
                    ForEach(shown) { box in
                        OptionRow(
                            symbol: "shippingbox.fill",
                            title: Marking.formatContainer(box.number),
                            detail: [
                                Words.size(box.equipmentType),
                                (box.isLoaded ?? false) ? "Loaded" : "Empty",
                                box.latitude == nil ? "Not on the map" : "On the map",
                            ].compactMap { $0 }.joined(separator: " · ")
                        ) { onPick(box) }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Place a Container")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
