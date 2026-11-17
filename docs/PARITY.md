# Sensible Logistics → Yard Link: feature and workflow parity

This is the checklist the rebuild is held to. Every feature of the original application is listed with where it lives in Yard Link and its state.

**How parity is kept:** the original server, shared rule modules and web screens were carried into this repository and changed in place, not rewritten. A workflow marked *Carried* is the original code with the Yard Link brand applied.

State key: **Carried** unchanged · **Changed** deliberately different · **New** · **Open** not done yet.

## 1. Accounts and access

| Feature | Original | Yard Link | State |
| :-- | :-- | :-- | :-- |
| Sign in with email and password | `/login` | Same | Carried |
| Sign up as driver or dispatcher with a company code | `/signup`, code from an environment variable | Same page; the **join code** lives in the database and is replaced from Settings | Changed |
| Confirm the account | Emailed link (`/verify-email`, resend) | Both: a dispatcher approves under Drivers (can be turned off in Settings), and when email is set up the person gets a welcome email and confirms the address from it (`/verify-email`, resend) | Carried + New |
| Locked account message | Login | Same | Carried |
| Driver roster, search, lock/unlock, reset password, last sign-in | `/admin/drivers` | Same, plus **Waiting for approval** | Carried + New |
| Profile, email, password, phone, CDL / truck details for time cards | More → Settings, `/admin/account` | Same, plus switches for email copies (work assignments, new messages, new accounts to approve) | Carried + New |
| Hidden operator codes (`SL-CLR` clear records, `SL-API` connections) | More | `SL-CLR` kept. `SL-API` opened the Quo page, which no longer exists | Changed |
| Clear records by type | `/reset` | Same | Carried |
| First-run setup | Environment variables | Setup wizard at `/setup`: database, company, first dispatcher, email, phone address | New |
| Database | `DATABASE_URL` environment variable | External PostgreSQL string entered in the wizard (or `DATABASE_URL`); skipping uses the built-in database with a data-loss warning | Changed |
| Company profile, timezone | Read-only page, values from environment | Editable under Settings | Changed |

## 2. Driver workflows

| Workflow | Screens | State |
| :-- | :-- | :-- |
| Home: active trip card, swap pair, today's tasks, day tally | `/` | Carried |
| New pickup wizard: kind → location → on-site inventory or typed entry → classify → seal → notes → destination → confirm | `/pickups/new` | Carried |
| Container or bare-chassis pickup; reuse / reactivate / create / conflict resolution of a container number | server `activePool` | Carried |
| Driver-hold and chassis-in-use prompts with release | pickup, add equipment | Carried |
| Read container and chassis numbers from a photo (server OCR) | scan steps, `/scan` | Carried |
| ISO 6346 check digit, masked entry, correction candidates | shared `iso6346` | Carried |
| Add a container to a chassis already on a trip | `/pickups/attach` | Carried |
| Arrive / drop-off: drop both, or drop the box and keep the chassis (opens a chassis-only trip) | `/trips/:id/dropoff` | Carried |
| Customer swap: empty in, load out, paired trips | Home, pickup wizard | Carried |
| Change drop-off destination | `/trips/:id/destination` | Carried |
| Cancel trip, clear trip, delete from history | Home, trip page | Carried |
| Correct the seal (double tap) | trip page | Carried |
| Trip documents and photos | Documents sheet | Carried (kept on the phone, as before). Sending an update now also saves the chosen files on the server |
| Send pickup / drop-off / swap update to dispatch | "Send SMS" share sheet | **Send update**: posts to the dispatch conversation with photos; the share sheet is still there as *Share* | Changed |
| Trip contacts (site phone lines, copy, dial) | Contacts sheet | Carried |
| Trips list and calendar, day summaries | `/pickups` | Carried |
| Trip gaps: confirm a bobtail move or mark a missing trip | Trips | Carried |
| Daily time card: stops from trips and GPS pings, manual edits, shift totals, PDF, blank Word template | `/pickups/time-card/:date` | Carried |
| Tasks: dispatch cards, checklist steps, split / merge, mark done, start pickup from a task, add a note | `/tasks` | Carried |
| Tasks arriving by forwarded SMS (Quo webhook) | Quo | Removed with Quo. Dispatch assigns cards directly; a driver can turn any dispatch message into a task with **Add to Tasks** | Changed |
| Locations list and search across locations, containers and chassis | `/containers` | Carried |
| Location page: on-site equipment, notes (expire after a month), counts by line | `/locations/:id` | Carried |
| Add equipment wizard | `/locations/:id/add` | Carried |
| Location audit: checklist, add, move, delete | `/locations/:id/audit` | Carried |
| CSX pickup list: type or photograph, review, claim on pickup | `/locations/:id/csx` | Carried |
| Export a location list as text, site CSV, directory CSV | Location, More | Carried |
| Add / edit location with address search, an automatic map pin you can drag, and an arrival radius | `/locations/new`, `/edit` | Carried + Changed |
| Yard view and yard generation from map data | `/locations/:id/yard` | Carried |
| Container page: status, photos and documents, ShipCSX check, edit, move, delete | `/containers/:id` | Carried; history section replaced (section 4) |
| Chassis page: status, edit, delete, release | `/chassis/:id` | Carried; history section replaced (section 4) |

## 3. Dispatcher workflows

| Workflow | Screens | State |
| :-- | :-- | :-- |
| Map board of locations and the container pool, inspect a box | `/admin` | Carried |
| Dispatch desk: pick driver and day, build task cards, bulk add from a location, draft / send, history | `/admin/dispatch` | Carried. The driver is told in Messages, and by email if they turned that on |
| Inventory: locations table and containers table with filters and paging | `/admin/inventory` | Carried |
| Drivers | `/admin/drivers` | Carried + approvals |
| Settings and system status | `/admin/settings` | Rebuilt: editable, with the connection code |
| Messages | — | New: `/messages` |
| Console layout and assignment improvements | — | **Open** (section 7) |

## 4. Equipment history (rebuilt)

Problems found in the original:

- A container page only ever showed the **current** service life, cut out of the event list at read time. Earlier lives could not be opened.
- Nothing identified a service life. A reused container number relied on slicing by terminal drop-offs, so a missing drop-off merged two lives.
- A chassis page reused the container slicing: a terminal return by *any* box the chassis carried ended the chassis's "service life", and events were pulled in through the trip's current chassis, so swapping chassis moved history between records.

Yard Link:

- `container_duty_cycles`: one row per cycle with its own id, a per-container sequence, start and end place, trip and driver. The database allows one active cycle per container.
- Every event and trip carries `duty_cycle_id`. The cycle is chosen when the event is recorded, in the same transaction.
- A cycle opens on the first confirmed pickup (or when a box is first recorded at a yard or customer) and completes on drop-off at a marine terminal or rail yard. If a box is collected from a terminal while a cycle is still open, the old cycle is closed and flagged, and a new one starts.
- A cycle whose opening pickup is cancelled is marked cancelled, not deleted.
- Existing history is given cycles on first start by replaying the same rules.
- Container page: cycle selector, summary (started, returned, drivers, chassis), event timeline.
- Chassis page: every container carried, with the duty cycle and who paired and separated it, then the full trail.

## 5. Integrations

| Integration | Original | Yard Link | State |
| :-- | :-- | :-- | :-- |
| Email (SMTP) | Verification, email-change notice, task assignment mail, test send; configured by environment variables | All four kept, plus welcome, approval, new-message and new-sign-up emails in the Yard Link brand. Configured in the wizard and under Settings; optional | Carried + New |
| Quo SMS | Settings page, inbound webhook → tasks | Removed | Changed |
| OCR | On-server OpenOCR worker | Same | Carried |
| ShipCSX public lookup | Manual check and 30-minute poll, enabled by environment variable | Same; terminal and on/off are in Settings | Changed |
| Address search (Photon / Nominatim), map tiles | Same | Same | Carried |
| File storage | Not implemented (SeaweedFS placeholder; no upload route) | Files on the server's data volume; upload, list, delete routes | New |
| Deployment | External Postgres, SeaweedFS, required environment variables | One compose file with its own database; no environment variables | Changed |

## 6. iPhone app: what is native

The iPhone app keeps no rules of its own. Each screen calls the same server route the web app calls, and nothing opens a browser.

It also borrows the web app's shell: a slim navy brand strip across the top of each main screen, the page's own title and controls beneath it, and a white bottom bar with the same five destinations and Tasks raised on a blue disc. Screens pushed on top of those (a trip, a container, a form) use a white bar with a blue Back link instead.

| Screen | On the phone |
| :-- | :-- |
| Connect to Your Employer (QR or typed address), sign in, sign out, disconnect | Yes |
| Home: greeting and today's counts, trip card, swap pair, Documents, Send Update, Contacts, Swap, the next-step button, Add Container to Chassis, Cancel Trip, Clear Trip, today's dispatch tasks, Messages | Yes |
| Pickup: container or bare chassis, location, pick from what is on site or the CSX list, type or photograph the number (server reads it), line, size, seal, notes, drop-off, confirm, resume, cancel | Yes |
| Swap pickup and adding a container to a bare chassis | Yes |
| Driver-hold and chassis-release questions during a pickup | Yes |
| Set or change drop-off, correct the seal | Yes |
| Arrive: drop both / drop the box and keep the chassis; keep or park a bare chassis; notes; position stamp | Yes |
| Documents on a trip or a container: take, view, remove. Stored on the server | Yes |
| Send update to dispatch with the trip's files, share it another way, or hand it to the phone's Messages app with the photos attached | Yes |
| Trips by day, month calendar, trip page, cancel, delete, trip gaps (missing trip / bobtail) | Yes |
| Time cards: list, edit header and stops, add a stop, PDF, position pings while the app is open | Yes |
| Tasks: dispatch cards and notes by day, tick steps, edit steps (add, remove, split lines, join above), mark done, remove own note, add a note, start a pickup | Yes |
| Containers tab: grouped locations, search by location or equipment number, add a location | Yes |
| Location page: details, phones, equipment on site, notes, edit, Add Equipment (with camera), Audit (checklist, move, remove), CSX pickup list (type a row, or read a list from a photo) | Yes |
| Container page: status, duty-cycle selector, timeline, photos, ShipCSX check, edit, move, delete | Yes |
| Chassis page: status, pairings, trail, edit, release, delete | Yes |
| Messages | Yes |
| Tap any number — container, chassis, seal, phone, pickup — to copy it; long-press for the whole number, the owner block or the serial | Yes |
| More: account settings (name, email, mobile, password, license and truck), email preferences, export locations, clear records | Yes |

## 7. Open work

1. **Dispatcher console redesign** and dispatch assignment improvements. Dispatchers use the web console; the phone gives them Messages, the equipment lists and More.
2. **Communication notifications** — a Yard Link message showing the sender's face on the lock screen and passing a Focus. Needs a notification service extension.
3. **An iMessage extension** — a trip-update card inserted into a conversation from the iMessage app drawer.
4. **The iPhone screens compile but have not been run against a server.** Every push builds the app for the simulator (`.github/workflows/ios-build.yml`).
