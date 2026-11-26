import Foundation

// Shapes of the server's answers for trips, tasks, locations and equipment.
// Everything the server may leave out is optional, so a newer server does
// not break an older app.

/// A number the server may send as a number or, from an older build, as a
/// string. Either way the phone reads a number, and a shape it cannot read
/// leaves the field empty instead of breaking the whole answer.
struct LooseNumber: Decodable, Hashable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let number = try? single.decode(Double.self) {
            value = number
        } else if let text = try? single.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}

struct NamedPlace: Decodable, Hashable {
    let id: String?
    let name: String?
    let type: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let addressLine1: String?
    let mainPhone: String?
    let contactPhone: String?
    let contactName: String?
    /// The circle the phone watches to ask about arriving. Only the
    /// destination of a live trip carries one.
    private let latitude: LooseNumber?
    private let longitude: LooseNumber?
    let arrivalRadiusM: Int?

    /// The street address, for finding a site the dispatcher never pinned.
    var postalAddress: String? {
        let line = [addressLine1, city, [state, postalCode].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return line.isEmpty ? nil : line
    }

    /// Everything the watch needs, or nil when the site has no pin.
    var arrivalCircle: ArrivalWatch.WatchedSite? {
        guard let id, let latitude = latitude?.value, let longitude = longitude?.value else { return nil }
        return ArrivalWatch.WatchedSite(
            locationId: id,
            name: name ?? "this stop",
            latitude: latitude,
            longitude: longitude,
            radiusMeters: Double(arrivalRadiusM ?? 180)
        )
    }
}

struct NumberedEquipment: Decodable, Hashable {
    let id: String?
    let number: String?
}

struct PersonRef: Decodable, Hashable {
    let id: String?
    let name: String?
}

// MARK: - Trips

struct TripListItem: Decodable, Identifiable, Hashable {
    let id: String
    let reference: String?
    let status: String
    let isLoaded: Bool?
    let createdAt: Date?
    let pickedUpAt: Date?
    let droppedOffAt: Date?
    let completedAt: Date?
    let containerNumber: String?
    let containerType: String?
    let chassisNumber: String?
    let kind: String?
    let swapPairTripId: String?
    let originLocationId: String?
    let destinationLocationId: String?
    let originName: String?
    let destinationName: String?

    var isBareChassis: Bool { kind == "BARE_CHASSIS" }
    var title: String {
        if let containerNumber, !containerNumber.isEmpty { return containerNumber }
        if let chassisNumber, !chassisNumber.isEmpty { return "Chassis \(chassisNumber)" }
        return isBareChassis ? "Bare chassis" : "Trip"
    }
    /// The day this trip is filed under in the list.
    var day: Date { pickedUpAt ?? createdAt ?? droppedOffAt ?? Date() }
}

/// What the driver said about a break between two trips.
struct TripGapAnswer: Decodable, Hashable {
    let priorTripId: String
    let nextTripId: String
    /// MISSING or BOBTAIL.
    let resolution: String
}

struct TripList: Decodable {
    let items: [TripListItem]
    let gapResolutions: [TripGapAnswer]?
}

/// What answering a gap sends back. A genuinely missing trip is no longer
/// resolved here — the driver records it for real (POST /api/trips/manual)
/// — so a confirmed gap is always a bobtail.
struct GapResolutionResult: Decodable {
    let priorTripId: String
    let nextTripId: String
    let resolution: String
}

/// A break in the chain of trips: the earlier one ended somewhere other than
/// where the later one started. Either a trip was not recorded, or the
/// driver moved the tractor alone (a bobtail).
struct TripGap: Identifiable, Hashable {
    let priorTripId: String
    let nextTripId: String
    let fromName: String
    let toName: String
    /// The two stops a trip recorded to fill this gap should use — present
    /// whenever both trips name a real location, not just free text.
    let fromLocationId: String?
    let toLocationId: String?

    var id: String { "\(priorTripId):\(nextTripId)" }

    /// Same reading of the trip list as the web app: oldest to newest, a gap
    /// wherever a drop-off is not the next pickup.
    static func find(in trips: [TripListItem]) -> [TripGap] {
        func stamp(_ trip: TripListItem) -> Date { trip.pickedUpAt ?? trip.createdAt ?? .distantPast }
        func place(_ name: String?) -> String {
            (name ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let ordered = trips.sorted { stamp($0) == stamp($1) ? $0.id < $1.id : stamp($0) < stamp($1) }
        var gaps: [TripGap] = []
        for (prior, next) in zip(ordered, ordered.dropFirst()) {
            let fromName = (prior.destinationName ?? "").trimmingCharacters(in: .whitespaces)
            let toName = (next.originName ?? "").trimmingCharacters(in: .whitespaces)
            if prior.destinationLocationId == nil && fromName.isEmpty { continue }
            if next.originLocationId == nil && toName.isEmpty { continue }
            let same: Bool
            if let from = prior.destinationLocationId, let to = next.originLocationId {
                same = from == to
            } else {
                same = !place(fromName).isEmpty && place(fromName) == place(toName)
            }
            if same { continue }
            gaps.append(TripGap(
                priorTripId: prior.id,
                nextTripId: next.id,
                fromName: fromName.isEmpty ? "Unknown stop" : fromName,
                toName: toName.isEmpty ? "Unknown stop" : toName,
                fromLocationId: prior.destinationLocationId,
                toLocationId: next.originLocationId
            ))
        }
        return gaps
    }
}

struct TripRecord: Decodable, Hashable {
    let id: String
    let reference: String?
    let status: String
    let kind: String?
    let isLoaded: Bool?
    let sealNumber: String?
    let customer: String?
    let notes: String?
    let driverNotes: String?
    let chassisId: String?
    let originLocationId: String?
    let destinationLocationId: String?
    let swapPairTripId: String?
    let createdAt: Date?
    let pickedUpAt: Date?
    let droppedOffAt: Date?

    var isLive: Bool { ["PICKUP_IN_PROGRESS", "IN_TRANSIT", "DROPOFF_IN_PROGRESS"].contains(status) }
    var isBareChassis: Bool { kind == "BARE_CHASSIS" }
}

struct TripContainer: Decodable, Hashable {
    let id: String?
    let number: String?
    let numberNormalized: String?
    let containerType: String?
    let equipmentType: String?
}

struct TripEvent: Decodable, Identifiable, Hashable {
    let id: String
    let eventType: String
    let occurredAt: Date?
    let notes: String?
    let locationName: String?
    let chassisNumber: String?
    let actorFirstName: String?
    let actorLastName: String?

    var actorName: String? {
        let name = [actorFirstName, actorLastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }
}

struct TripDetail: Decodable {
    let trip: TripRecord
    let container: TripContainer?
    let chassis: NumberedEquipment?
    let origin: NamedPlace?
    let destination: NamedPlace?
    let timeline: [TripEvent]?
}

// MARK: - Starting a pickup

/// A container at a location, or one on that location's CSX pickup list.
struct YardBox: Decodable, Identifiable, Hashable {
    let id: String
    let number: String
    let numberNormalized: String?
    let containerType: String?
    let equipmentType: String?
    let isLoaded: Bool?
    let sealNumber: String?
    let currentChassisId: String?
    let chassisNumber: String?
    let pickupNumber: String?
    let csxRelease: Bool?

    var isCsxRelease: Bool { (csxRelease ?? false) || id.hasPrefix("csx:") }
}

/// A chassis parked at a location with nothing on it.
struct YardChassis: Decodable, Identifiable, Hashable {
    let id: String
    let number: String
    let provider: String?
    let sizeCompatibility: String?
}

struct SiteInventory: Decodable {
    let containers: [YardBox]
    let chassis: [YardChassis]
    let csxReleases: [YardBox]?
}

/// What is at the drop-off of an empty inbound, for a customer swap.
struct SwapSite: Decodable {
    let destination: NamedPlace
    let containers: [YardBox]?
    let chassis: [YardChassis]?
}

/// What the server would do with a typed container number.
struct PoolResolution: Decodable {
    struct Found: Decodable {
        let id: String
        let number: String?
        let containerType: String?
        let equipmentType: String?
    }

    struct Holder: Decodable {
        let driverName: String?
    }

    /// CREATE, REUSE_ACTIVE, REACTIVATE or CONFLICT.
    let outcome: String
    let container: Found?
    let holder: Holder?
    let message: String?
}

struct ChassisLookup: Decodable {
    struct Item: Decodable {
        let id: String
        let number: String
        let currentContainerId: String?
        let currentContainerNumber: String?
    }

    let item: Item
}

struct TripEnvelope: Decodable {
    struct Ref: Decodable {
        let id: String
    }

    let trip: Ref
}

/// Numbers the server read from a photo.
struct ScanResult: Decodable {
    let container: String?
    let chassis: String?
    let message: String?
}

// MARK: - Documents

struct DocumentItem: Decodable, Identifiable, Hashable {
    let id: String
    let category: String?
    let fileName: String
    let mimeType: String?
    let createdAt: Date?

    var isImage: Bool { (mimeType ?? "").hasPrefix("image/") }

    /// The name without its extension, which is what the driver named it.
    var title: String {
        let name = (fileName as NSString).deletingPathExtension
        return name.isEmpty ? fileName : name
    }
}

struct DocumentList: Decodable {
    let items: [DocumentItem]
}

/// Equipment on the driver's active trip right now, with a count of the
/// files filed against it and one to show as a thumbnail.
struct DocumentGroup: Decodable, Identifiable, Hashable {
    let tripId: String
    let containerNumber: String?
    let chassisNumber: String?
    let count: Int
    let previewDocumentId: String?

    var id: String { tripId }

    var title: String {
        [containerNumber, chassisNumber].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " on ")
    }
}

struct DocumentGroupList: Decodable {
    let groups: [DocumentGroup]
}

struct DocumentEnvelope: Decodable {
    struct Ref: Decodable {
        let id: String
    }

    let document: Ref
}

// MARK: - Tasks

struct TaskStep: Codable, Identifiable, Hashable {
    let id: String
    var text: String
    var done: Bool
}

struct TaskCard: Decodable, Hashable {
    let kind: String?
    let notes: String?
    let locationName: String?
    let destinationLocationName: String?
    let containerNumber: String?
    let containerPending: Bool?
}

struct DriverTask: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let rawText: String?
    let workDate: String?
    let kind: String?
    var status: String
    let source: String?
    let assigned: Bool?
    let editable: Bool?
    let tripId: String?
    var steps: [TaskStep]?
    let card: TaskCard?

    var isOpen: Bool { status == "OPEN" || status == "IN_PROGRESS" }
    var sourceLabel: String { (assigned ?? false) ? "Dispatch" : "Your note" }
}

struct TaskList: Decodable {
    let todayIso: String?
    let tasks: [DriverTask]
}

struct TaskEnvelope: Decodable {
    let task: DriverTask
}

// MARK: - Locations

struct LocationListItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String?
    let addressLine1: String?
    let city: String?
    let state: String?
    let occupancy: Int?
    let availableChassis: Int?
    let isUncategorized: Bool?
    let matchedNumbers: [String]?

    var addressLine: String {
        [addressLine1, [city, state].compactMap { $0 }.joined(separator: ", ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct EquipmentHit: Decodable, Identifiable, Hashable {
    let kind: String
    let id: String
    let number: String
    let locationName: String?
}

struct LocationList: Decodable {
    let items: [LocationListItem]
    let equipment: [EquipmentHit]?
}

struct LocationRecord: Decodable, Hashable {
    let id: String
    let name: String
    let type: String?
    let latitude: Double?
    let longitude: Double?
    /// How close a phone has to be for Yard Link to ask about arriving.
    let arrivalRadiusM: Int?
    let addressLine1: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let hours: String?
    let mainPhone: String?
    let contactName: String?
    let contactPhone: String?
    let gateInstructions: String?
    let driverNotes: String?
    let shipcsxTerminal: String?
    let isUncategorized: Bool?
}

/// A location as the add and edit forms send it. Only the fields the phone
/// asks for; the map outline and heading are left to the web app.
struct LocationInput: Encodable {
    var name = ""
    var type = "CUSTOMER"
    var addressLine1 = ""
    var city = ""
    var state = ""
    var postalCode = ""
    var hours = ""
    var mainPhone = ""
    var contactName = ""
    var contactPhone = ""
    var gateInstructions = ""
    var driverNotes = ""
    var shipcsxTerminal = ""
    var appointmentRequired = false

    init() {}

    init(_ record: LocationRecord) {
        name = record.name
        type = record.type ?? "CUSTOMER"
        addressLine1 = record.addressLine1 ?? ""
        city = record.city ?? ""
        state = record.state ?? ""
        postalCode = record.postalCode ?? ""
        hours = record.hours ?? ""
        mainPhone = record.mainPhone ?? ""
        contactName = record.contactName ?? ""
        contactPhone = record.contactPhone ?? ""
        gateInstructions = record.gateInstructions ?? ""
        driverNotes = record.driverNotes ?? ""
        shipcsxTerminal = record.shipcsxTerminal ?? ""
    }
}

struct LocationEnvelope: Decodable {
    struct Ref: Decodable {
        let id: String
    }

    let location: Ref
}

struct SiteContainer: Decodable, Identifiable, Hashable {
    let id: String
    let number: String
    let containerType: String?
    let equipmentType: String?
    let isLoaded: Bool?
    let sealNumber: String?
    let chassisNumber: String?
    let doNotMove: Bool?
}

struct SiteChassis: Decodable, Identifiable, Hashable {
    let id: String
    let number: String
    let provider: String?
    let status: String?
}

struct LocationNote: Decodable, Identifiable, Hashable {
    let id: String
    let body: String
    let authorName: String?
    let createdAt: Date?
    let expiresAt: Date?
    let mine: Bool?
}

struct LocationNoteEnvelope: Decodable {
    let note: LocationNote
}

struct LocationDetail: Decodable {
    let location: LocationRecord
    let occupancy: Int?
    let containers: [SiteContainer]?
    let chassis: [SiteChassis]?
    let notes: [LocationNote]?
    let csxReleases: [CsxRelease]?
}

/// Preformatted "Export list" text for a location — generated server-side
/// by the same shared formatter the web app's Export sheet uses, so the
/// phone never has to re-derive the masking and layout rules itself.
struct LocationExportResult: Decodable {
    let text: String
    let noteCount: Int
}

// MARK: - Equipment history

struct HistoryEvent: Decodable, Identifiable, Hashable {
    let id: String
    let eventType: String
    let occurredAt: Date?
    let tripReference: String?
    let dutyCycleId: String?
    let containerId: String?
    let containerNumber: String?
    let chassisId: String?
    let chassisNumber: String?
    let locationName: String?
    let driverName: String?
    let notes: String?
    let isLoaded: Bool?
    let sealNumber: String?
}

struct DutyCycle: Decodable, Identifiable, Hashable {
    let id: String
    let sequence: Int
    let status: String
    let startedAt: Date?
    let startLocation: NamedPlace?
    let completedAt: Date?
    let endLocation: NamedPlace?
    let closedByNextPickup: Bool?
    let drivers: [String]?
    let chassis: [NumberedEquipment]?
    let events: [HistoryEvent]?

    var statusLabel: String {
        switch status {
        case "ACTIVE": return "Active"
        case "COMPLETED": return "Complete"
        case "VOIDED": return "Cancelled"
        default: return status.capitalized
        }
    }
}

struct ContainerHistory: Decodable {
    let cycles: [DutyCycle]
    let unfiled: [HistoryEvent]?
}

struct ContainerRecord: Decodable, Hashable {
    let id: String
    let number: String
    let containerType: String?
    let equipmentType: String?
    let isLoaded: Bool?
    let sealNumber: String?
    let containerStatus: String?
    let activePoolState: String?
}

struct ContainerDetail: Decodable {
    let container: ContainerRecord
    let currentLocation: NamedPlace?
    let currentChassis: NumberedEquipment?
    let currentDriver: PersonRef?
    let history: ContainerHistory?
    /// What ShipCSX said the last time anyone checked.
    let shipcsx: ShipcsxSnapshot?
}

struct ChassisPairing: Decodable, Identifiable, Hashable {
    let containerId: String?
    let containerNumber: String?
    let dutyCycleId: String?
    let dutyCycleSequence: Int?
    let dutyCycleStatus: String?
    let pairedAt: Date?
    let pairedLocationName: String?
    let pairedByDriverName: String?
    let separatedAt: Date?
    let separatedLocationName: String?
    let separatedByDriverName: String?

    var id: String { "\(containerId ?? "-")|\(dutyCycleId ?? "-")|\(pairedAt?.timeIntervalSince1970 ?? 0)" }
}

struct ChassisHistory: Decodable {
    let events: [HistoryEvent]
    let pairings: [ChassisPairing]?
}

struct ChassisRecord: Decodable, Hashable {
    let id: String
    let number: String
    let provider: String?
    let status: String?
    let sizeCompatibility: String?
    let licensePlate: String?
    let notes: String?
    let outOfService: Bool?
}

/// A container on a terminal's CSX pickup list, with its pickup number.
struct CsxRelease: Decodable, Identifiable, Hashable {
    let id: String
    let containerNumber: String
    let pickupNumber: String?
}

struct CsxReleaseList: Decodable {
    let releases: [CsxRelease]
}

struct ChassisDetail: Decodable {
    let chassis: ChassisRecord
    let currentLocation: NamedPlace?
    let currentContainer: NumberedEquipment?
    let history: ChassisHistory?
}

// MARK: - Words shown for server values

/// Display names only. What a status *means* is decided by the server.
enum Words {
    static func tripStatus(_ status: String) -> String {
        switch status {
        case "DRAFT": return "Draft"
        case "PICKUP_IN_PROGRESS": return "Pickup in progress"
        case "IN_TRANSIT": return "In transit"
        case "DROPOFF_IN_PROGRESS": return "Drop-off in progress"
        case "DROPPED_OFF": return "Dropped off"
        case "COMPLETED": return "Completed"
        case "CANCELLED": return "Cancelled"
        case "EXCEPTION": return "Exception"
        default: return plain(status)
        }
    }

    static func locationType(_ type: String?) -> String {
        switch type {
        case "COMPANY_YARD": return "Company yard"
        case "CUSTOMER": return "Customer"
        case "MARINE_TERMINAL": return "Marine terminal"
        case "RAIL_TERMINAL": return "Rail yard"
        default: return "Location"
        }
    }

    static func locationSymbol(_ type: String?) -> String {
        switch type {
        case "COMPANY_YARD": return "parkingsign.circle.fill"
        case "CUSTOMER": return "building.2.fill"
        case "MARINE_TERMINAL": return "ferry.fill"
        case "RAIL_TERMINAL": return "tram.fill"
        default: return "mappin.circle.fill"
        }
    }

    static func line(_ type: String?) -> String? {
        switch type {
        case "TROPICAL": return "Tropical"
        case "ZIM": return "ZIM"
        case "CMA": return "CMA"
        case "KING_OCEAN": return "King Ocean"
        default: return nil
        }
    }

    static func size(_ type: String?) -> String? {
        switch type {
        case "DRY_20": return "20' Dry"
        case "DRY_40": return "40' Dry"
        case "HC_40": return "40' HC"
        case "HC_45": return "45' HC"
        case "REEFER": return "Reefer"
        case "TANK": return "Tank"
        case "OPEN_TOP": return "Open top"
        case "FLAT_RACK": return "Flat rack"
        case "OTHER": return "Other"
        default: return nil
        }
    }

    static func containerStatus(_ status: String?) -> String? {
        switch status {
        case "AVAILABLE": return "Available"
        case "IN_TRANSIT": return "In transit"
        case "AT_YARD": return "On site"
        case "LOADING": return "Loading"
        case "RETURNED": return "Returned"
        case .none: return nil
        default: return plain(status ?? "")
        }
    }

    /// What happened, in the driver's words. A pickup that names a chassis
    /// moved both pieces of equipment at once, and says so. Hooking up to a
    /// box already on a chassis is a pickup, never a mounting.
    static func event(_ record: HistoryEvent) -> String {
        let hasChassis = !(record.chassisNumber ?? "").isEmpty
        let bareChassis = record.containerId == nil && hasChassis
        switch record.eventType {
        case "PICKUP_CONFIRMED":
            if bareChassis { return "Chassis picked up" }
            return hasChassis ? "Container and chassis picked up" : "Picked up"
        case "DROPOFF_CONFIRMED":
            if bareChassis { return "Chassis dropped off" }
            return "Dropped off"
        default:
            return event(record.eventType)
        }
    }

    /// A trip always moves a container, so a chassis on the event never
    /// makes it a bare-chassis move.
    static func event(_ record: TripEvent) -> String {
        let hasChassis = !(record.chassisNumber ?? "").isEmpty
        switch record.eventType {
        case "PICKUP_CONFIRMED":
            return hasChassis ? "Container and chassis picked up" : "Picked up"
        default:
            return event(record.eventType)
        }
    }

    static func event(_ type: String) -> String {
        switch type {
        case "PICKUP_STARTED": return "Pickup started"
        case "PICKUP_CONFIRMED": return "Picked up"
        case "DROPOFF_STARTED": return "Drop-off started"
        case "DROPOFF_CONFIRMED": return "Dropped off"
        case "GATE_IN": return "Gate in"
        case "GATE_OUT": return "Gate out"
        case "ARRIVED": return "Arrived"
        case "DEPARTED": return "Departed"
        case "YARD_MOVE": return "Yard move"
        case "CHASSIS_ATTACH": return "Placed on chassis"
        case "CHASSIS_DETACH": return "Removed from chassis"
        case "LOADED": return "Loaded"
        case "EMPTIED": return "Emptied"
        case "DOCUMENT_ADDED": return "Document added"
        case "DAMAGE_REPORTED": return "Damage reported"
        case "CORRECTION": return "Correction"
        case "STATUS_CHANGE": return "Status change"
        case "RELEASED": return "Released"
        case "ACTIVATED": return "Added to active pool"
        case "PICKUP_CANCELLED": return "Pickup cancelled"
        default: return plain(type)
        }
    }

    static func eventSymbol(_ type: String) -> String {
        switch type {
        case "PICKUP_STARTED", "PICKUP_CONFIRMED": return "arrow.up.circle.fill"
        case "DROPOFF_STARTED", "DROPOFF_CONFIRMED": return "arrow.down.circle.fill"
        case "CHASSIS_ATTACH": return "link.circle.fill"
        case "CHASSIS_DETACH": return "minus.circle.fill"
        case "PICKUP_CANCELLED": return "xmark.circle.fill"
        case "YARD_MOVE": return "arrow.left.arrow.right.circle.fill"
        default: return "circle.fill"
        }
    }

    static func taskKind(_ kind: String?) -> String {
        switch kind {
        case "PICKUP": return "Pickup"
        case "DROPOFF": return "Drop-off"
        case "LOAD": return "Live load"
        case "EMPTY": return "Empty"
        case "WORK": return "Work"
        default: return "Dispatch"
        }
    }

    private static func plain(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Time cards

struct TimeCardListItem: Decodable, Identifiable, Hashable {
    let workDate: String
    let status: String
    let stopCount: Int?
    let totalOnDutyHours: String?

    var id: String { workDate }
}

struct TimeCardList: Decodable {
    let items: [TimeCardListItem]
}

/// One line of the day: in, out, where, and what was done there.
struct TimeCardStop: Codable, Identifiable, Hashable {
    var key: String
    var timeIn: String
    var timeOut: String
    var location: String
    var activity: String
    /// TRIP, GPS or MANUAL: where the line came from.
    var source: String?
    var tripId: String?
    var locationId: String?
    /// The trip's customer, mirrored on both its pickup and drop-off stop.
    var customer: String?
    var corrected: Bool?

    var id: String { key }
}

/// The top of the card. The server fills the totals from the stops.
struct TimeCardHeader: Codable, Hashable {
    var driverName: String?
    var truckUnit: String?
    var trailerNumber: String?
    var cdl: String?
    var employeeId: String?
    var dispatcher: String?
    var routeCustomer: String?
    var startOdometer: String?
    var endOdometer: String?
    var reportForDuty: String?
    var releasedFromDuty: String?
    var totalOnDutyHours: String?
}

struct TimeCard: Decodable {
    let workDate: String
    let status: String
    let header: TimeCardHeader
    let stops: [TimeCardStop]
}

struct TimeCardEnvelope: Decodable {
    let card: TimeCard
}

// MARK: - ShipCSX

/// What ShipCSX said about a container the last time someone checked it.
struct ShipcsxSnapshot: Decodable, Hashable {
    let terminalName: String?
    let loadEmpty: String?
    let waybillDate: String?
    let gateWindow: String?
    let inGateReadiness: String?
    let resultTab: String?
    let error: String?
    let checkedAt: Date?

    /// The same wording the web app shows.
    var statusLabel: String {
        if let readiness = inGateReadiness?.trimmingCharacters(in: .whitespaces), !readiness.isEmpty { return readiness }
        if error != nil { return "Couldn't check" }
        switch resultTab?.replacingOccurrences(of: "-", with: "_") {
        case "NOTIFIED": return "Notified"
        case "ENROUTE": return "En route"
        case "IN_GATE": return "In-gate"
        case "OTHERS": return "Other"
        case "NOT_FOUND": return "Not on CSX"
        default: return "Checked"
        }
    }

    var detailLine: String {
        [terminalName, loadEmpty, waybillDate.map { "Waybill \($0)" }, gateWindow]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// CSX facilities Yard Link can look up. Fixed list, as on the server.
let shipcsxTerminals = ["North Bergen", "Little Ferry", "South Kearny", "Elizabeth", "Newark"]

// MARK: - A CSX list read from a photo

struct CsxListPair: Decodable, Identifiable, Hashable {
    let containerNumber: String
    let pickupNumber: String
    /// `high` when one container and one pickup number shared a line.
    let confidence: String

    var id: String { "\(containerNumber):\(pickupNumber)" }
}

struct CsxListParse: Decodable {
    let pairs: [CsxListPair]
    let leftoverContainers: [String]
    let leftoverPickups: [String]
}

// MARK: - Clearing records

struct ResetCounts: Decodable {
    let locations: Int
    let containers: Int
    let trips: Int
    let chassis: Int
    let documents: Int
    let tasks: Int
    let trucks: Int
    let users: Int

    func count(_ id: String) -> Int {
        switch id {
        case "locations": return locations
        case "containers": return containers
        case "trips": return trips
        case "chassis": return chassis
        case "documents": return documents
        case "tasks": return tasks
        case "trucks": return trucks
        default: return users
        }
    }
}

/// What can be cleared, in the server's order and wording.
let resetTargets: [(id: String, label: String, hint: String)] = [
    ("locations", "Customers and locations", "Yards, terminals and customer sites"),
    ("containers", "Containers", "Boxes and their history"),
    ("trips", "Trips", "Pickups, drop-offs and movement history"),
    ("chassis", "Chassis", "Company chassis records"),
    ("documents", "Documents", "EIRs, PODs and uploads"),
    ("tasks", "Tasks", "Assigned dispatch cards and driver notes"),
    ("trucks", "Trucks", "Company trucks"),
    ("users", "Users", "Other accounts. Yours stays."),
]

// MARK: - Fuel receipts

/// What the server read off a just-snapped receipt photo. A starting point
/// for the confirm form, never saved as-is.
struct FuelReceiptExtraction: Decodable {
    let gallons: Double?
    let totalAmount: Double?
    let pricePerGallon: Double?
    let stationName: String?
    let stationAddress: String?
    /// The date printed on the receipt, "yyyy-MM-dd", or nil to mean "use now".
    let printedDate: String?
    /// The time printed with it, 24-hour "HH:mm:ss". It is wall-clock time
    /// where the fuel was bought, so it is read in the phone's own time zone.
    let printedTime: String?
    let invoiceNumber: String?
    let fuelType: String?
    let cardLast4: String?
    let authCode: String?
    let rawText: String

    /// The printed date and time as one moment in the phone's time zone. With
    /// a date but no time, `fallback`'s time of day is kept on that date.
    func printedMoment(fallback: Date) -> Date? {
        guard let printedDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if let printedTime {
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let moment = formatter.date(from: "\(printedDate) \(printedTime)") { return moment }
        }
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: printedDate) else { return nil }
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute, .second], from: fallback)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
    }
}

struct FuelReceiptExtractionEnvelope: Decodable {
    let extraction: FuelReceiptExtraction
}

struct FuelReceiptSummary: Decodable, Identifiable, Hashable {
    let id: String
    let purchasedAt: Date
    let gallons: Double
    let totalAmount: Double
    let pricePerGallon: Double?
    let stationName: String?
    let stationAddress: String?
    let invoiceNumber: String?
    let fuelType: String?
    let cardLast4: String?
    let authCode: String?
    let notes: String?
}

struct FuelReceiptWeek: Decodable, Identifiable, Hashable {
    let weekStart: String
    let weekEnd: String
    let receipts: [FuelReceiptSummary]
    let totalGallons: Double
    let totalAmount: Double
    let averagePricePerGallon: Double?

    var id: String { weekStart }
}

struct FuelReceiptWeekList: Decodable {
    let weeks: [FuelReceiptWeek]
}

struct FuelReceiptEnvelope: Decodable {
    let receipt: FuelReceiptSummary
}

// MARK: - Bridge crossing times

/// Which side the lane is headed toward, exactly as the Port Authority's own feed names it.
enum BridgeCrossingDirection: String, Decodable {
    case towardNY = "ToNY"
    case towardNJ = "ToNJ"
}

enum BridgeCrossingTrend: String, Decodable {
    case improving = "IMPROVING"
    case worsening = "WORSENING"
    case steady = "STEADY"
}

/// One crossing's current reading in one direction. The GWB's lower level is
/// never sent — only its upper level counts as "the George Washington Bridge" here.
struct BridgeCrossingLane: Decodable, Identifiable, Hashable {
    let facilityId: Int
    let crossingName: String
    let direction: BridgeCrossingDirection
    let travelTimeMinutes: Int
    let typicalTimeMinutes: Int?
    let isClosed: Bool
    let trend: BridgeCrossingTrend
    let sourceTimestamp: String?
    let recordedAt: Date

    var id: String { "\(facilityId):\(direction.rawValue)" }
}

struct BridgeCrossingLaneList: Decodable {
    let lanes: [BridgeCrossingLane]
    /// When the newest reading in `lanes` was taken. The server refreshes
    /// on-demand whenever this would otherwise be more than five minutes
    /// old, so this is mostly just a "how fresh is this" stamp for the page.
    let lastUpdated: Date?
}

/// One point on a lane's 24-hour graph.
struct BridgeCrossingHistoryPoint: Decodable, Identifiable, Hashable {
    let travelTimeMinutes: Int
    let typicalTimeMinutes: Int?
    let isClosed: Bool
    let recordedAt: Date

    var id: Date { recordedAt }
}

struct BridgeCrossingDetail: Decodable {
    let lane: BridgeCrossingLane
    let history: [BridgeCrossingHistoryPoint]
    let lastUpdated: Date?
}
