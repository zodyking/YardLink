/* ============================================================
   Geospatial storage
   A site is a point and a radius in plain columns, so the app runs on a
   stock PostgreSQL server with no extensions. Distances are computed with
   the haversine formula.
   ============================================================ */

/**
 * Yard Link — PostgreSQL schema (Drizzle ORM).
 *
 * Design rules enforced here (spec 17, 18):
 *  - Every tenant-scoped table carries `company_id`.
 *  - All timestamps are `timestamptz` (UTC); display timezone lives on the location.
 *  - `containers` holds denormalised current-state fields that are only ever
 *    written inside the same transaction as the authoritative `container_events` row.
 *  - A normalised container number is unique per company, active or not.
 *  - At most one active movement claim may exist per container (partial unique index).
 */

import { sql } from 'drizzle-orm'
import {
  boolean,
  date,
  index,
  integer,
  jsonb,
  numeric,
  pgEnum,
  pgTable,
  real,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from 'drizzle-orm/pg-core'

const utc = (name: string) => timestamp(name, { withTimezone: true, mode: 'date' })

/* ============================================================
   Enums
   ============================================================ */

export const roleEnum = pgEnum('role', ['DRIVER', 'ADMIN'])
export const membershipStatusEnum = pgEnum('membership_status', ['PENDING', 'ACTIVE', 'SUSPENDED'])
export const driverStatusEnum = pgEnum('driver_status', ['AVAILABLE', 'ON_TRIP', 'OFF_DUTY', 'INACTIVE'])

export const activePoolStateEnum = pgEnum('active_pool_state', [
  'INACTIVE',
  'PICKUP_IN_PROGRESS',
  'DRIVER_CUSTODY',
  'AT_LOCATION',
  'EXCEPTION',
])

export const containerTypeEnum = pgEnum('container_type', ['TROPICAL', 'ZIM', 'CMA', 'KING_OCEAN'])

export const containerStatusEnum = pgEnum('container_status', [
  'AVAILABLE',
  'IN_TRANSIT',
  'AT_YARD',
  'LOADING',
  'RETURNED',
])

export const equipmentTypeEnum = pgEnum('equipment_type', [
  'DRY_20',
  'DRY_40',
  'HC_40',
  'HC_45',
  'REEFER',
  'TANK',
  'OPEN_TOP',
  'FLAT_RACK',
  'OTHER',
])

export const chassisStatusEnum = pgEnum('chassis_status', ['AVAILABLE', 'IN_USE', 'OUT_OF_SERVICE'])

export const tripStatusEnum = pgEnum('trip_status', [
  'DRAFT',
  'PICKUP_IN_PROGRESS',
  'IN_TRANSIT',
  'DROPOFF_IN_PROGRESS',
  'DROPPED_OFF',
  'COMPLETED',
  'CANCELLED',
  'EXCEPTION',
])

export const eventTypeEnum = pgEnum('event_type', [
  'PICKUP_STARTED',
  'PICKUP_CONFIRMED',
  'DROPOFF_STARTED',
  'DROPOFF_CONFIRMED',
  'GATE_IN',
  'GATE_OUT',
  'ARRIVED',
  'DEPARTED',
  'YARD_MOVE',
  'CHASSIS_ATTACH',
  'CHASSIS_DETACH',
  'LOADED',
  'EMPTIED',
  'DOCUMENT_ADDED',
  'DAMAGE_REPORTED',
  'CORRECTION',
  'STATUS_CHANGE',
  'RELEASED',
  'ACTIVATED',
  'PICKUP_CANCELLED',
])

export const eventSourceEnum = pgEnum('event_source', [
  'MANUAL',
  'OCR',
  'GEOFENCE',
  'IMPORT',
  'API',
  'ADMIN_EDIT',
  'SYSTEM',
])

export const locationTypeEnum = pgEnum('location_type', [
  'COMPANY_YARD',
  'CUSTOMER',
  'MARINE_TERMINAL',
  'RAIL_TERMINAL',
])

export const locationStatusEnum = pgEnum('location_status', ['ACTIVE', 'PENDING_APPROVAL', 'ARCHIVED'])

export const documentCategoryEnum = pgEnum('document_category', [
  'EIR',
  'POD',
  'BILL_OF_LADING',
  'DELIVERY_ORDER',
  'GATE_TICKET',
  'SCALE_TICKET',
  'DAMAGE_REPORT',
  'REPAIR_INVOICE',
  'CUSTOMS',
  'PHOTO',
  'OTHER',
])

export const ocrStatusEnum = pgEnum('ocr_status', ['PENDING', 'RUNNING', 'COMPLETED', 'FAILED', 'NOT_IMPLEMENTED'])
export const ocrSourceTypeEnum = pgEnum('ocr_source_type', ['CONTAINER', 'CHASSIS', 'SEAL', 'DOCUMENT'])
export const ocrValidationEnum = pgEnum('ocr_validation_status', ['VALID', 'INVALID', 'UNVERIFIED'])

export const damageSeverityEnum = pgEnum('damage_severity', ['MINOR', 'MODERATE', 'SEVERE', 'OUT_OF_SERVICE'])

export const notificationStatusEnum = pgEnum('notification_status', ['PENDING', 'DELIVERED', 'READ', 'DISMISSED'])

export const dispatchTaskKindEnum = pgEnum('dispatch_task_kind', [
  'PICKUP',
  'DROPOFF',
  'LOAD',
  'EMPTY',
  'WORK',
  'NOTE',
])
export const dispatchTaskStatusEnum = pgEnum('dispatch_task_status', [
  'DRAFT',
  'OPEN',
  'IN_PROGRESS',
  'DONE',
  'DISMISSED',
])
export const dispatchTaskSourceEnum = pgEnum('dispatch_task_source', ['SMS', 'MANUAL', 'DISPATCH'])

export const dutyCycleStatusEnum = pgEnum('duty_cycle_status', ['ACTIVE', 'COMPLETED', 'VOIDED'])
export const messageThreadKindEnum = pgEnum('message_thread_kind', ['DISPATCH', 'DIRECT'])

export const csxReleaseStatusEnum = pgEnum('csx_release_status', [
  'OPEN',
  'CLAIMED',
  'PICKED_UP',
  'CANCELLED',
])
export const csxReleaseSourceEnum = pgEnum('csx_release_source', ['MANUAL', 'OCR'])
export const csxLookupTabEnum = pgEnum('csx_lookup_tab', [
  'NOTIFIED',
  'ENROUTE',
  'IN_GATE',
  'OTHERS',
  'NOT_FOUND',
])

/* ============================================================
   Tenancy and identity
   ============================================================ */

export const companies = pgTable('companies', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: text('name').notNull(),
  legalName: text('legal_name'),
  usdotNumber: text('usdot_number'),
  /** Shared code used by the public driver signup flow to join a company. */
  inviteCode: text('invite_code').notNull(),
  timezone: text('timezone').notNull().default('America/New_York'),
  settings: jsonb('settings').$type<Record<string, unknown>>().notNull().default({}),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [uniqueIndex('companies_invite_code_key').on(t.inviteCode)])

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  email: text('email').notNull(),
  passwordHash: text('password_hash').notNull(),
  firstName: text('first_name').notNull(),
  lastName: text('last_name').notNull(),
  mobileNumber: text('mobile_number'),
  emailVerifiedAt: utc('email_verified_at'),
  /** Unused leftover. Signup and Settings collect a number without SMS verification. */
  phoneVerifiedAt: utc('phone_verified_at'),
  profilePhotoUrl: text('profile_photo_url'),
  lastLoginAt: utc('last_login_at'),
  disabledAt: utc('disabled_at'),
  /** Cheat-code unlocks for this user until they enter the same code again. */
  unlockedFeatures: jsonb('unlocked_features').$type<string[]>().notNull().default([]),
  /** Topics this person also wants by email, e.g. `{ assignments: true }`. */
  emailPrefs: jsonb('email_prefs').$type<Record<string, boolean>>().notNull().default({}),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [uniqueIndex('users_email_key').on(sql`lower(${t.email})`)])

/**
 * Single-use email confirmation links, sent when someone signs up and the
 * employer has set up outgoing email.
 *
 * Only the SHA-256 digest of the token is stored, so a database leak cannot be
 * replayed to take over an unverified account. Rows are kept after use as an
 * audit trail of which address was confirmed and when.
 */
export const emailVerificationTokens = pgTable('email_verification_tokens', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  tokenHash: text('token_hash').notNull(),
  /** Address the link was sent to — may differ from the current user email. */
  sentToEmail: text('sent_to_email').notNull(),
  expiresAt: utc('expires_at').notNull(),
  consumedAt: utc('consumed_at'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('email_verification_tokens_hash_key').on(t.tokenHash),
  index('email_verification_tokens_user_idx').on(t.userId),
])

/**
 * One row per phone signed in to Yard Link, so the server can push a message
 * or an assignment to it. Apple hands the app a new token whenever it feels
 * like it, so the token is the key and the row is refreshed on every sign-in.
 */
export const deviceTokens = pgTable('device_tokens', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  /** APNs device token, hex. */
  token: text('token').notNull(),
  platform: text('platform').notNull().default('ios'),
  /** Development builds talk to Apple's sandbox. */
  sandbox: boolean('sandbox').notNull().default(false),
  appVersion: text('app_version'),
  lastSeenAt: utc('last_seen_at').notNull().defaultNow(),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('device_tokens_token_key').on(t.token),
  index('device_tokens_user_idx').on(t.userId),
])

export const companyMemberships = pgTable('company_memberships', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  /** Exactly one role per membership (spec 3). */
  role: roleEnum('role').notNull(),
  status: membershipStatusEnum('status').notNull().default('ACTIVE'),
  invitedByUserId: uuid('invited_by_user_id'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('company_memberships_company_user_key').on(t.companyId, t.userId),
  index('company_memberships_user_idx').on(t.userId),
])

export const drivers = pgTable('drivers', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  driverCode: text('driver_code'),
  cdlNumber: text('cdl_number'),
  cdlState: text('cdl_state'),
  /** Normal work reporting location — anchors the 150 air-mile radius check. */
  homeTerminalLocationId: uuid('home_terminal_location_id'),
  preferredTruckId: uuid('preferred_truck_id'),
  status: driverStatusEnum('status').notNull().default('AVAILABLE'),
  emergencyContactName: text('emergency_contact_name'),
  emergencyContactPhone: text('emergency_contact_phone'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('drivers_company_user_key').on(t.companyId, t.userId),
  index('drivers_company_idx').on(t.companyId),
])

export const trucks = pgTable('trucks', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  unitNumber: text('unit_number').notNull(),
  plate: text('plate'),
  vin: text('vin'),
  assignedDriverId: uuid('assigned_driver_id'),
  active: boolean('active').notNull().default(true),
  notes: text('notes'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [uniqueIndex('trucks_company_unit_key').on(t.companyId, t.unitNumber)])

/* ============================================================
   Locations and geospatial model
   ============================================================ */

export const locations = pgTable('locations', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
  type: locationTypeEnum('type').notNull(),
  locationCode: text('location_code'),
  aliases: jsonb('aliases').$type<string[]>().notNull().default([]),

  addressLine1: text('address_line1'),
  addressLine2: text('address_line2'),
  city: text('city'),
  state: text('state'),
  postalCode: text('postal_code'),
  country: text('country').notNull().default('US'),
  /** Lower-cased, whitespace-collapsed address used for duplicate detection. */
  normalizedAddress: text('normalized_address'),

  /** Site point, geocoded from the address and movable by hand. */
  latitude: numeric('latitude', { precision: 10, scale: 7 }),
  longitude: numeric('longitude', { precision: 10, scale: 7 }),
  /** How far from the point still counts as being at this site, in metres. */
  arrivalRadiusM: integer('arrival_radius_m').notNull().default(180),

  timezone: text('timezone').notNull().default('America/New_York'),
  hours: text('hours'),
  appointmentRequired: boolean('appointment_required').notNull().default(false),
  /** Switchboard / main company line for this site. */
  mainPhone: text('main_phone'),
  contactName: text('contact_name'),
  contactPhone: text('contact_phone'),
  gateInstructions: text('gate_instructions'),
  driverNotes: text('driver_notes'),
  /** ShipCSX dropdown label, e.g. `North Bergen`. */
  shipcsxTerminal: text('shipcsx_terminal'),
  capacity: integer('capacity'),

  status: locationStatusEnum('status').notNull().default('ACTIVE'),
  createdByUserId: uuid('created_by_user_id'),
  approvedByUserId: uuid('approved_by_user_id'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
  deletedAt: utc('deleted_at'),
  /** Holding yard for equipment whose site was deleted. */
  isUncategorized: boolean('is_uncategorized').notNull().default(false),
}, t => [
  index('locations_company_idx').on(t.companyId),
  index('locations_company_name_idx').on(t.companyId, t.name),
  index('locations_normalized_address_idx').on(t.companyId, t.normalizedAddress),
  uniqueIndex('locations_one_uncategorized_per_company')
    .on(t.companyId)
    .where(sql`is_uncategorized = true and deleted_at is null`),
])

/** Yard board notes. Live rows expire one calendar month after they are left. */
export const locationNotes = pgTable('location_notes', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  locationId: uuid('location_id').notNull().references(() => locations.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'set null' }),
  authorName: text('author_name').notNull(),
  body: text('body').notNull(),
  createdAt: utc('created_at').notNull().defaultNow(),
  expiresAt: utc('expires_at').notNull(),
}, t => [
  index('location_notes_location_idx').on(t.locationId, t.expiresAt),
  index('location_notes_company_idx').on(t.companyId),
])

export const locationZones = pgTable('location_zones', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  locationId: uuid('location_id').notNull().references(() => locations.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
  purpose: text('purpose'),
  capacity: integer('capacity'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [index('location_zones_location_idx').on(t.locationId)])

/* ============================================================
   Equipment
   ============================================================ */

export const chassis = pgTable('chassis', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  number: text('number').notNull(),
  numberNormalized: text('number_normalized').notNull(),
  provider: text('provider'),
  sizeCompatibility: text('size_compatibility'),
  licensePlate: text('license_plate'),
  vin: text('vin'),
  status: chassisStatusEnum('status').notNull().default('AVAILABLE'),
  outOfService: boolean('out_of_service').notNull().default(false),
  currentContainerId: uuid('current_container_id'),
  currentLocationId: uuid('current_location_id'),
  notes: text('notes'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
  deletedAt: utc('deleted_at'),
}, t => [
  uniqueIndex('chassis_company_number_key').on(t.companyId, t.numberNormalized),
  index('chassis_company_idx').on(t.companyId),
])

export const containers = pgTable('containers', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),

  /** As displayed, e.g. `MSCU 452189-4`. */
  number: text('number').notNull(),
  /** Uppercase, punctuation-stripped. Unique per company, active or not (spec 18). */
  numberNormalized: text('number_normalized').notNull(),
  checkDigitValid: boolean('check_digit_valid').notNull().default(false),

  /** Business classification — distinct from equipment size/type (spec 5.1). */
  containerType: containerTypeEnum('container_type').notNull(),
  equipmentType: equipmentTypeEnum('equipment_type').notNull().default('DRY_40'),
  isLoaded: boolean('is_loaded').notNull().default(false),
  /**
   * Where the box sits in the current service life (customer drop-off →
   * Loading). Distinct from cargo loaded/empty and from active-pool state.
   */
  containerStatus: containerStatusEnum('container_status').notNull().default('AVAILABLE'),

  sealNumber: text('seal_number'),
  bookingNumber: text('booking_number'),
  billOfLading: text('bill_of_lading'),
  customerReference: text('customer_reference'),
  purchaseOrder: text('purchase_order'),
  releaseNumber: text('release_number'),
  commodity: text('commodity'),
  steamshipLine: text('steamship_line'),
  terminalReference: text('terminal_reference'),

  /* --- Denormalised current state, written only alongside an event --- */
  activePoolState: activePoolStateEnum('active_pool_state').notNull().default('INACTIVE'),
  currentDriverId: uuid('current_driver_id'),
  currentLocationId: uuid('current_location_id'),
  activeMovementId: uuid('active_movement_id'),
  currentChassisId: uuid('current_chassis_id'),
  activatedAt: utc('activated_at'),
  releasedAt: utc('released_at'),
  lastActivityAt: utc('last_activity_at'),

  /* --- Deadlines and financial exposure --- */
  availabilityDate: date('availability_date'),
  lastFreeDay: date('last_free_day'),
  emptyReturnDeadline: date('empty_return_deadline'),
  appointmentAt: utc('appointment_at'),

  /* --- Special handling flags --- */
  isReefer: boolean('is_reefer').notNull().default(false),
  isHazmat: boolean('is_hazmat').notNull().default(false),
  isOverweight: boolean('is_overweight').notNull().default(false),
  isDamaged: boolean('is_damaged').notNull().default(false),
  customsHold: boolean('customs_hold').notNull().default(false),
  isUrgent: boolean('is_urgent').notNull().default(false),
  doNotMove: boolean('do_not_move').notNull().default(false),

  notes: text('notes'),
  tags: jsonb('tags').$type<string[]>().notNull().default([]),
  /** Optimistic-locking counter for mutable state (spec 18). */
  version: integer('version').notNull().default(1),

  createdByUserId: uuid('created_by_user_id'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
  deletedAt: utc('deleted_at'),
}, t => [
  uniqueIndex('containers_company_number_key').on(t.companyId, t.numberNormalized),
  index('containers_company_state_idx').on(t.companyId, t.activePoolState),
  index('containers_company_status_idx').on(t.companyId, t.containerStatus),
  index('containers_current_location_idx').on(t.currentLocationId),
  index('containers_current_driver_idx').on(t.currentDriverId),
])

/* ============================================================
   Movements
   ============================================================ */

export const trips = pgTable('trips', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  /** Human-readable work-order reference, e.g. `TRP-1042`. */
  reference: text('reference').notNull(),
  driverId: uuid('driver_id').notNull().references(() => drivers.id),
  truckId: uuid('truck_id'),
  containerId: uuid('container_id').references(() => containers.id),
  chassisId: uuid('chassis_id'),
  /** CONTAINER (box on a chassis or bobtail) or BARE_CHASSIS (chassis only). */
  kind: text('kind').notNull().default('CONTAINER'),

  originLocationId: uuid('origin_location_id'),
  destinationLocationId: uuid('destination_location_id'),

  status: tripStatusEnum('status').notNull().default('DRAFT'),
  isLoaded: boolean('is_loaded').notNull().default(false),
  sealNumber: text('seal_number'),
  customer: text('customer'),
  steamshipLine: text('steamship_line'),
  referenceNumbers: jsonb('reference_numbers').$type<Record<string, string>>().notNull().default({}),

  plannedPickupAt: utc('planned_pickup_at'),
  appointmentAt: utc('appointment_at'),
  plannedDeliveryAt: utc('planned_delivery_at'),
  pickedUpAt: utc('picked_up_at'),
  droppedOffAt: utc('dropped_off_at'),
  completedAt: utc('completed_at'),
  cancelledAt: utc('cancelled_at'),

  /** Marks the drop-off that removes the container from the active pool. */
  isFinalRelease: boolean('is_final_release').notNull().default(false),
  exceptionType: text('exception_type'),
  driverNotes: text('driver_notes'),
  reviewNotes: text('review_notes'),
  requiredDocuments: jsonb('required_documents').$type<string[]>().notNull().default([]),
  /** The paired movement in an empty-for-load customer swap. */
  swapPairTripId: uuid('swap_pair_trip_id'),
  /** Container duty cycle this movement belongs to. Null for bare-chassis trips. */
  dutyCycleId: uuid('duty_cycle_id'),
  version: integer('version').notNull().default(1),

  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('trips_company_reference_key').on(t.companyId, t.reference),
  index('trips_driver_status_idx').on(t.driverId, t.status),
  index('trips_company_status_idx').on(t.companyId, t.status),
  /**
   * At most one live movement claim per container (spec 18). Enforced in the
   * database so two drivers racing on the same number cannot both win.
   */
  uniqueIndex('trips_one_active_claim_per_container')
    .on(t.containerId)
    .where(sql`status in ('PICKUP_IN_PROGRESS','IN_TRANSIT','DROPOFF_IN_PROGRESS')`),
  index('trips_swap_pair_idx').on(t.swapPairTripId),
])

/** Driver-confirmed deadhead between two trips whose places do not chain. */
export const tripGaps = pgTable('trip_gaps', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  driverId: uuid('driver_id').notNull().references(() => drivers.id, { onDelete: 'cascade' }),
  priorTripId: uuid('prior_trip_id').notNull().references(() => trips.id, { onDelete: 'cascade' }),
  nextTripId: uuid('next_trip_id').notNull().references(() => trips.id, { onDelete: 'cascade' }),
  resolution: text('resolution').notNull().default('BOBTAIL'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('trip_gaps_pair_key').on(t.priorTripId, t.nextTripId),
  index('trip_gaps_driver_idx').on(t.driverId),
])

export const tripStops = pgTable('trip_stops', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  tripId: uuid('trip_id').notNull().references(() => trips.id, { onDelete: 'cascade' }),
  sequence: integer('sequence').notNull(),
  locationId: uuid('location_id'),
  plannedAt: utc('planned_at'),
  arrivedAt: utc('arrived_at'),
  departedAt: utc('departed_at'),
  notes: text('notes'),
}, t => [uniqueIndex('trip_stops_trip_sequence_key').on(t.tripId, t.sequence)])

/* ============================================================
   Immutable event timeline
   ============================================================ */

export const containerEvents = pgTable('container_events', {
  /**
   * Client-generated UUID. Reused verbatim on offline retries so the insert is
   * naturally idempotent (spec 20, 33.2).
   */
  id: uuid('id').primaryKey(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  containerId: uuid('container_id').references(() => containers.id, { onDelete: 'cascade' }),

  eventType: eventTypeEnum('event_type').notNull(),
  /** Actual moment the event happened in the real world. */
  occurredAt: utc('occurred_at').notNull(),
  /** Moment the record reached the server — delayed entry stays visible. */
  createdAt: utc('created_at').notNull().defaultNow(),

  actorUserId: uuid('actor_user_id'),
  actorDriverId: uuid('actor_driver_id'),
  source: eventSourceEnum('source').notNull().default('MANUAL'),

  tripId: uuid('trip_id'),
  locationId: uuid('location_id'),
  chassisId: uuid('chassis_id'),
  gpsLatitude: numeric('gps_latitude', { precision: 10, scale: 7 }),
  gpsLongitude: numeric('gps_longitude', { precision: 10, scale: 7 }),
  /** Reported accuracy in metres; stored with every geofence-derived signal. */
  gpsAccuracyMeters: real('gps_accuracy_meters'),

  /** Structured payload: previous/next state, seal, notes, OCR references. */
  payload: jsonb('payload').$type<Record<string, unknown>>().notNull().default({}),
  notes: text('notes'),

  /** Set when this row records a correction to an earlier event. */
  correctsEventId: uuid('corrects_event_id'),
  /** Duty cycle of the container this event is filed under. */
  dutyCycleId: uuid('duty_cycle_id'),
}, t => [
  index('container_events_container_idx').on(t.containerId, t.occurredAt),
  index('container_events_chassis_idx').on(t.chassisId, t.occurredAt),
  index('container_events_cycle_idx').on(t.dutyCycleId),
  index('container_events_company_idx').on(t.companyId, t.occurredAt),
  index('container_events_trip_idx').on(t.tripId),
])

/**
 * One working life of a physical container: from leaving a marine terminal or
 * rail yard until it is returned to one. Container identity (`containers`),
 * the cycle, and the dispatch work (`trips`, `dispatch_tasks`) are separate
 * records, so a reused container number never collides with its own past.
 */
export const containerDutyCycles = pgTable('container_duty_cycles', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  containerId: uuid('container_id').notNull().references(() => containers.id, { onDelete: 'cascade' }),
  /** 1-based count of this container's cycles. */
  sequence: integer('sequence').notNull(),
  status: dutyCycleStatusEnum('status').notNull().default('ACTIVE'),
  startedAt: utc('started_at').notNull(),
  startEventId: uuid('start_event_id'),
  startLocationId: uuid('start_location_id'),
  startTripId: uuid('start_trip_id'),
  startDriverId: uuid('start_driver_id'),
  completedAt: utc('completed_at'),
  endEventId: uuid('end_event_id'),
  endLocationId: uuid('end_location_id'),
  endTripId: uuid('end_trip_id'),
  endDriverId: uuid('end_driver_id'),
  /** Closed because the next terminal pickup proved the box had gone back. */
  closedByNextPickup: boolean('closed_by_next_pickup').notNull().default(false),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('container_duty_cycles_sequence_key').on(t.containerId, t.sequence),
  /** At most one active cycle per container, enforced by the database. */
  uniqueIndex('container_duty_cycles_one_active')
    .on(t.containerId)
    .where(sql`status = 'ACTIVE'`),
  index('container_duty_cycles_company_idx').on(t.companyId, t.status),
])

/**
 * A phone crossing into a site's circle while a trip is live. The driver is
 * asked whether they have arrived; if nobody answers, the arrival is recorded
 * anyway at the moment of the crossing, never at the moment of the sweep.
 */
export const tripArrivals = pgTable('trip_arrivals', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  tripId: uuid('trip_id').notNull().references(() => trips.id, { onDelete: 'cascade' }),
  driverId: uuid('driver_id').notNull().references(() => drivers.id, { onDelete: 'cascade' }),
  locationId: uuid('location_id').notNull().references(() => locations.id, { onDelete: 'cascade' }),
  /** When the phone crossed in. The arrival is always stamped with this. */
  enteredAt: utc('entered_at').notNull(),
  /** When the driver stops being asked and the arrival is recorded anyway. */
  autoAt: utc('auto_at').notNull(),
  latitude: numeric('latitude', { precision: 10, scale: 7 }),
  longitude: numeric('longitude', { precision: 10, scale: 7 }),
  accuracyMeters: real('accuracy_meters'),
  settledAt: utc('settled_at'),
  /** CONFIRMED by the driver, AUTO after the wait, or DISMISSED by the driver. */
  outcome: text('outcome'),
  eventId: uuid('event_id'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [
  index('trip_arrivals_open_idx').on(t.settledAt, t.autoAt),
  uniqueIndex('trip_arrivals_trip_location_key').on(t.tripId, t.locationId),
])

/* ============================================================
   Documents, OCR, damage
   ============================================================ */

export const documents = pgTable('documents', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  category: documentCategoryEnum('category').notNull().default('OTHER'),
  fileName: text('file_name').notNull(),
  mimeType: text('mime_type').notNull(),
  sizeBytes: integer('size_bytes').notNull().default(0),
  /** Object key inside the private SeaweedFS S3 bucket — never a public URL. */
  storageKey: text('storage_key').notNull(),
  thumbnailKey: text('thumbnail_key'),
  checksum: text('checksum'),

  containerId: uuid('container_id'),
  tripId: uuid('trip_id'),
  chassisId: uuid('chassis_id'),
  locationId: uuid('location_id'),
  eventId: uuid('event_id'),

  /** Flat text index built from OCR output for global search (spec 11). */
  extractedText: text('extracted_text'),
  ocrStatus: ocrStatusEnum('ocr_status').notNull().default('PENDING'),
  replacesDocumentId: uuid('replaces_document_id'),
  uploadedByUserId: uuid('uploaded_by_user_id'),
  createdAt: utc('created_at').notNull().defaultNow(),
  deletedAt: utc('deleted_at'),
}, t => [
  index('documents_company_idx').on(t.companyId, t.createdAt),
  index('documents_container_idx').on(t.containerId),
  index('documents_trip_idx').on(t.tripId),
])

export const ocrResults = pgTable('ocr_results', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  sourceDocumentId: uuid('source_document_id'),
  sourceType: ocrSourceTypeEnum('source_type').notNull(),

  engine: text('engine').notNull().default('paddleocr'),
  engineVersion: text('engine_version'),
  modelName: text('model_name'),
  /** Which OpenCV preprocessing profile and crop produced this attempt. */
  preprocessingProfile: text('preprocessing_profile'),

  status: ocrStatusEnum('status').notNull().default('PENDING'),
  startedAt: utc('started_at'),
  completedAt: utc('completed_at'),

  rawResponse: jsonb('raw_response').$type<Record<string, unknown>>(),
  detectedRegions: jsonb('detected_regions').$type<unknown[]>(),
  /** Ranked candidates, not a single magic string (spec 34). */
  candidateValues: jsonb('candidate_values').$type<unknown[]>(),
  selectedValue: text('selected_value'),
  confidence: real('confidence'),
  validationStatus: ocrValidationEnum('validation_status').notNull().default('UNVERIFIED'),
  checkDigitValid: boolean('check_digit_valid'),

  reviewedByUserId: uuid('reviewed_by_user_id'),
  reviewedAt: utc('reviewed_at'),
  correctionReason: text('correction_reason'),
  latencyMs: integer('latency_ms'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [index('ocr_results_company_idx').on(t.companyId, t.createdAt)])

export const damageReports = pgTable('damage_reports', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  containerId: uuid('container_id'),
  chassisId: uuid('chassis_id'),
  tripId: uuid('trip_id'),
  eventId: uuid('event_id'),
  severity: damageSeverityEnum('severity').notNull().default('MINOR'),
  area: text('area'),
  description: text('description').notNull(),
  reportedByUserId: uuid('reported_by_user_id'),
  resolvedAt: utc('resolved_at'),
  resolutionNotes: text('resolution_notes'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [index('damage_reports_company_idx').on(t.companyId, t.createdAt)])

/** A driver's own diesel receipt, snapped in Settings and tracked weekly. */
export const fuelReceipts = pgTable('fuel_receipts', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  driverId: uuid('driver_id').notNull().references(() => drivers.id, { onDelete: 'cascade' }),
  purchasedAt: utc('purchased_at').notNull(),
  gallons: numeric('gallons', { precision: 8, scale: 3 }).notNull(),
  totalAmount: numeric('total_amount', { precision: 10, scale: 2 }).notNull(),
  /** Always `totalAmount / gallons` — never read separately off the receipt. */
  pricePerGallon: numeric('price_per_gallon', { precision: 8, scale: 3 }),
  stationName: text('station_name'),
  stationAddress: text('station_address'),
  invoiceNumber: text('invoice_number'),
  fuelType: text('fuel_type'),
  cardLast4: text('card_last4'),
  authCode: text('auth_code'),
  storageKey: text('storage_key').notNull(),
  mimeType: text('mime_type').notNull(),
  sizeBytes: integer('size_bytes').notNull().default(0),
  /** Raw OCR transcript, kept so a bad read can be checked against the photo. */
  ocrText: text('ocr_text'),
  notes: text('notes'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
  deletedAt: utc('deleted_at'),
}, t => [
  index('fuel_receipts_company_idx').on(t.companyId, t.purchasedAt),
  index('fuel_receipts_driver_idx').on(t.driverId, t.purchasedAt),
])

/* ============================================================
   Notifications and audit
   ============================================================ */

export const notifications = pgTable('notifications', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  kind: text('kind').notNull(),
  title: text('title').notNull(),
  body: text('body'),
  /** In-app route the notification points at. */
  deepLink: text('deep_link'),
  status: notificationStatusEnum('status').notNull().default('PENDING'),
  readAt: utc('read_at'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [index('notifications_user_idx').on(t.userId, t.status)])

export const auditLogs = pgTable('audit_logs', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  actorUserId: uuid('actor_user_id'),
  action: text('action').notNull(),
  entityType: text('entity_type').notNull(),
  entityId: uuid('entity_id'),
  before: jsonb('before').$type<Record<string, unknown>>(),
  after: jsonb('after').$type<Record<string, unknown>>(),
  ipAddress: text('ip_address'),
  userAgent: text('user_agent'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [index('audit_logs_company_idx').on(t.companyId, t.createdAt)])

/* ============================================================
   Dispatch desk → driver tasks
   Dispatchers compose dated cards (draft or submitted). Drivers can add
   their own notes but cannot rewrite an assigned card. The SMS webhook
   table is leftover from the old phone-forwarding path and is unused.
   ============================================================ */

export const smsInboundEndpoints = pgTable('sms_inbound_endpoints', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  driverId: uuid('driver_id').notNull().references(() => drivers.id, { onDelete: 'cascade' }),
  token: text('token').notNull(),
  lastReceivedAt: utc('last_received_at'),
  lastTestAt: utc('last_test_at'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('sms_inbound_endpoints_token_key').on(t.token),
  uniqueIndex('sms_inbound_endpoints_driver_key').on(t.driverId),
])

export const dispatchTasks = pgTable('dispatch_tasks', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  driverId: uuid('driver_id').notNull().references(() => drivers.id, { onDelete: 'cascade' }),
  source: dispatchTaskSourceEnum('source').notNull().default('MANUAL'),
  rawText: text('raw_text').notNull(),
  sender: text('sender'),
  receivedAt: utc('received_at').notNull().defaultNow(),
  workDate: date('work_date').notNull(),
  kind: dispatchTaskKindEnum('kind').notNull().default('NOTE'),
  title: text('title').notNull(),
  parsed: jsonb('parsed').$type<Record<string, unknown>>().notNull().default({}),
  status: dispatchTaskStatusEnum('status').notNull().default('OPEN'),
  sortOrder: integer('sort_order').notNull().default(0),
  tripId: uuid('trip_id').references(() => trips.id, { onDelete: 'set null' }),
  fingerprint: text('fingerprint').notNull(),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('dispatch_tasks_driver_fingerprint_key').on(t.driverId, t.fingerprint),
  index('dispatch_tasks_driver_work_date_idx').on(t.driverId, t.workDate),
  index('dispatch_tasks_trip_idx').on(t.tripId),
])

/* ============================================================
   ShipCSX pickup releases and shipment snapshots
   ============================================================ */

export const csxPickupReleases = pgTable('csx_pickup_releases', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  locationId: uuid('location_id').notNull().references(() => locations.id, { onDelete: 'cascade' }),
  containerId: uuid('container_id').references(() => containers.id, { onDelete: 'set null' }),
  containerNumber: text('container_number').notNull(),
  containerNumberNormalized: text('container_number_normalized').notNull(),
  pickupNumber: text('pickup_number').notNull(),
  status: csxReleaseStatusEnum('status').notNull().default('OPEN'),
  source: csxReleaseSourceEnum('source').notNull().default('MANUAL'),
  claimedTripId: uuid('claimed_trip_id').references(() => trips.id, { onDelete: 'set null' }),
  pickedUpAt: utc('picked_up_at'),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  index('csx_pickup_releases_location_idx').on(t.locationId, t.status),
  index('csx_pickup_releases_company_number_idx').on(t.companyId, t.containerNumberNormalized),
  uniqueIndex('csx_pickup_releases_open_key')
    .on(t.companyId, t.locationId, t.containerNumberNormalized)
    .where(sql`${t.status} in ('OPEN', 'CLAIMED')`),
])

export const csxShipmentSnapshots = pgTable('csx_shipment_snapshots', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  containerId: uuid('container_id').references(() => containers.id, { onDelete: 'set null' }),
  containerNumberNormalized: text('container_number_normalized').notNull(),
  terminalName: text('terminal_name').notNull(),
  equipmentNumber: text('equipment_number').notNull(),
  referenceUsed: text('reference_used').notNull().default('00'),
  resultTab: csxLookupTabEnum('result_tab').notNull().default('NOT_FOUND'),
  loadEmpty: text('load_empty'),
  waybillDate: text('waybill_date'),
  inGateReadiness: text('in_gate_readiness'),
  gateWindow: text('gate_window'),
  rawPayload: jsonb('raw_payload').$type<Record<string, unknown>>().notNull().default({}),
  error: text('error'),
  checkedAt: utc('checked_at').notNull().defaultNow(),
}, t => [
  index('csx_shipment_snapshots_container_idx').on(t.containerId, t.checkedAt),
  index('csx_shipment_snapshots_company_idx').on(t.companyId, t.checkedAt),
])

/* ============================================================
   Daily FMCSA short-haul time card (one row per driver per work date)
   ============================================================ */

export const driverTimeCards = pgTable('driver_time_cards', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  driverId: uuid('driver_id').notNull().references(() => drivers.id, { onDelete: 'cascade' }),
  workDate: date('work_date').notNull(),
  status: text('status').notNull().default('OPEN'),
  stops: jsonb('stops').$type<unknown[]>().notNull().default([]),
  pings: jsonb('pings').$type<unknown[]>().notNull().default([]),
  header: jsonb('header').$type<Record<string, string>>().notNull().default({}),
  headerOverrides: jsonb('header_overrides').$type<string[]>().notNull().default([]),
  createdAt: utc('created_at').notNull().defaultNow(),
  updatedAt: utc('updated_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('driver_time_cards_driver_date_key').on(t.driverId, t.workDate),
  index('driver_time_cards_company_idx').on(t.companyId, t.workDate),
])

export const csxPollState = pgTable('csx_poll_state', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  lastStartedAt: utc('last_started_at'),
  lastFinishedAt: utc('last_finished_at'),
  lastError: text('last_error'),
  skipUntil: utc('skip_until'),
  checkedCount: integer('checked_count').notNull().default(0),
}, t => [uniqueIndex('csx_poll_state_company_key').on(t.companyId)])

/* ============================================================
   Bridge crossing times (Port Authority of NY & NJ live feed)
   Not company-scoped: the six Hudson River crossings are the same for
   every company, so this is one shared, append-only history that the
   poller writes to on a timer. The "Bridge crossing times" company
   setting only decides whether a company's Tools page shows it.
   ============================================================ */

/** The feed's own direction labels, kept verbatim rather than translated. */
export const bridgeCrossingDirectionEnum = pgEnum('bridge_crossing_direction', ['ToNY', 'ToNJ'])

export const bridgeCrossingSnapshots = pgTable('bridge_crossing_snapshots', {
  id: uuid('id').primaryKey().defaultRandom(),
  facilityId: integer('facility_id').notNull(),
  crossingName: text('crossing_name').notNull(),
  direction: bridgeCrossingDirectionEnum('direction').notNull(),
  travelTimeMinutes: integer('travel_time_minutes').notNull(),
  /** The feed's own typical/historical baseline for this lane, if it sent one. */
  typicalTimeMinutes: integer('typical_time_minutes'),
  isClosed: boolean('is_closed').notNull().default(false),
  /** The feed gives a clock time only (no date), kept as-is for display. */
  sourceTimestamp: text('source_timestamp'),
  recordedAt: utc('recorded_at').notNull().defaultNow(),
}, t => [
  index('bridge_crossing_snapshots_lane_idx').on(t.facilityId, t.direction, t.recordedAt),
  index('bridge_crossing_snapshots_recorded_idx').on(t.recordedAt),
])

/* ============================================================
   Inferred types
   ============================================================ */

export type Company = typeof companies.$inferSelect
export type User = typeof users.$inferSelect
export type CompanyMembership = typeof companyMemberships.$inferSelect
export type Driver = typeof drivers.$inferSelect
export type Truck = typeof trucks.$inferSelect
export type Location = typeof locations.$inferSelect
export type LocationNote = typeof locationNotes.$inferSelect
export type Container = typeof containers.$inferSelect
export type Chassis = typeof chassis.$inferSelect
export type Trip = typeof trips.$inferSelect
export type TripGapRecord = typeof tripGaps.$inferSelect
export type ContainerEvent = typeof containerEvents.$inferSelect
export type DocumentRecord = typeof documents.$inferSelect
export type OcrResult = typeof ocrResults.$inferSelect
export type SmsInboundEndpoint = typeof smsInboundEndpoints.$inferSelect
export type DispatchTask = typeof dispatchTasks.$inferSelect
export type DriverTimeCard = typeof driverTimeCards.$inferSelect
export type TripArrival = typeof tripArrivals.$inferSelect
export type BridgeCrossingSnapshot = typeof bridgeCrossingSnapshots.$inferSelect

export type NewContainer = typeof containers.$inferInsert
export type NewContainerEvent = typeof containerEvents.$inferInsert
export type NewTrip = typeof trips.$inferInsert
export type NewLocation = typeof locations.$inferInsert
export type CsxPickupRelease = typeof csxPickupReleases.$inferSelect
export type CsxShipmentSnapshot = typeof csxShipmentSnapshots.$inferSelect

/* ============================================================
   Built-in messaging (replaces SMS; email is an optional copy)
   ============================================================ */

/**
 * A conversation. DISPATCH threads belong to one driver and are shared by
 * every dispatcher, so whoever is on the desk can answer. DIRECT threads are
 * between two people; `userLowId` < `userHighId` keeps each pair unique.
 */
export const messageThreads = pgTable('message_threads', {
  id: uuid('id').primaryKey().defaultRandom(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  kind: messageThreadKindEnum('kind').notNull(),
  /** DISPATCH: the driver's user id. */
  driverUserId: uuid('driver_user_id').references(() => users.id, { onDelete: 'cascade' }),
  userLowId: uuid('user_low_id').references(() => users.id, { onDelete: 'cascade' }),
  userHighId: uuid('user_high_id').references(() => users.id, { onDelete: 'cascade' }),
  lastMessageAt: utc('last_message_at'),
  lastMessagePreview: text('last_message_preview'),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('message_threads_dispatch_key').on(t.companyId, t.driverUserId).where(sql`kind = 'DISPATCH'`),
  uniqueIndex('message_threads_direct_key').on(t.companyId, t.userLowId, t.userHighId).where(sql`kind = 'DIRECT'`),
  index('message_threads_company_idx').on(t.companyId, t.lastMessageAt),
])

export const messages = pgTable('messages', {
  /** Client-generated so a retried send on a weak signal is not duplicated. */
  id: uuid('id').primaryKey(),
  companyId: uuid('company_id').notNull().references(() => companies.id, { onDelete: 'cascade' }),
  threadId: uuid('thread_id').notNull().references(() => messageThreads.id, { onDelete: 'cascade' }),
  /** Null for system notices such as "3 tasks assigned for Tue". */
  senderUserId: uuid('sender_user_id').references(() => users.id, { onDelete: 'set null' }),
  senderName: text('sender_name').notNull(),
  body: text('body').notNull(),
  /** TEXT, TRIP_UPDATE, TASKS, ACCOUNT. */
  kind: text('kind').notNull().default('TEXT'),
  tripId: uuid('trip_id'),
  /** Trip documents shared with the message. */
  documentIds: jsonb('document_ids').$type<string[]>().notNull().default([]),
  createdAt: utc('created_at').notNull().defaultNow(),
}, t => [
  index('messages_thread_idx').on(t.threadId, t.createdAt),
])

export const messageReads = pgTable('message_reads', {
  threadId: uuid('thread_id').notNull().references(() => messageThreads.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  lastReadAt: utc('last_read_at').notNull().defaultNow(),
}, t => [
  uniqueIndex('message_reads_key').on(t.threadId, t.userId),
])
