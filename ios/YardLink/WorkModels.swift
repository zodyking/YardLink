import Foundation

// Shapes of the server's answers for trips, tasks, locations and equipment.
// Everything the server may leave out is optional, so a newer server does
// not break an older app.

struct NamedPlace: Decodable, Hashable {
    let id: String?
    let name: String?
    let type: String?
    let city: String?
    let mainPhone: String?
    let contactPhone: String?
    let contactName: String?
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

struct TripList: Decodable {
    let items: [TripListItem]
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
}

struct DocumentList: Decodable {
    let items: [DocumentItem]
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
    let isUncategorized: Bool?
}

struct SiteContainer: Decodable, Identifiable, Hashable {
    let id: String
    let number: String
    let containerType: String?
    let equipmentType: String?
    let isLoaded: Bool?
    let sealNumber: String?
    let chassisNumber: String?
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
