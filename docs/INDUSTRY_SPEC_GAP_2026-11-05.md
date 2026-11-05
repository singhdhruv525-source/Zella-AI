# Owner's 28-industry spec against what Zella has (5 November 2026)

This compares the owner's spec (pasted 5 Nov) with the code on `main` at commit `1ace366`. That covers the industry
work in `docs/INDUSTRY_WORK_2026-11-04.md`, which is **built and tested but not yet applied to production**.

Legend: ✅ have · 🟡 partly (what's missing is named) · ❌ missing.
"Records" lines refer to industry record types and fields, which owners can extend under Customize records.

## What every industry already shares

| Spec area | Status |
|---|---|
| Customers, leads, tasks, notes, timeline, calls, messages | ✅ |
| Individual appointments, reminders, reschedule, no-show, cancellations | ✅ |
| Front-desk check-ins and waitlist (where switched on) | ✅ |
| Industry record types with statuses, linked to the customer and to each other (same business only) | ✅ |
| Private fields for codes and IDs: managers, plus assigned staff while a job is open; every view logged | ✅ |
| Today: bookings, open / overdue / due today per record type, calls, tasks | ✅ (not each industry's exact cards; see below) |
| Money: estimate proposed / accepted, invoice open / part paid / paid, deposits, no-show fees, gift cards, refunds; manual vs provider-confirmed | ✅ (records only; nothing is charged) |
| Capabilities that hide pages and are refused on the server | ✅ |
| AI receptionist safety lines per industry; no booking where none is taken | ✅ |
| Readiness ladder (saved → setup complete → integrations verified → ready → live) | ✅ |
| Photos on jobs, inspections and deliverables | ❌ (no file uploads on records) |
| Appointments linked to a record (vehicle, pet, property, class) | ❌ (appointments link to the customer only) |
| Dispatch board (technician by day, routes, travel buffers) and "on the way" text | ❌ (arrival window field only) |
| Resource booking (chair, room, bay, equipment) | ❌ |
| Multiple locations with staff limited to their location | ❌ |
| Guardian / proxy / vendor / owner logins (portals) | ❌ |
| Integrations with industry systems (workshop, PMS, EHR, store, booking engines, accounting) | ❌ (Google Calendar and Meta only) |

## Per industry

| # | Industry | Have | Missing (most important first) |
|---|---|---|---|
| 1 | Automotive | Vehicles: VIN, plate, plate state, registration, make, model, year, mileage, service due. Repair orders linked to the vehicle; statuses from diagnosing to collected; estimate, labour and parts costs; declined work with a reminder. Loaner cars. Check-ins for drop-off. "Never diagnose" line. | Fleets and drivers; inspections; additional-work approval recorded as an explicit authorization; parts-delay status; warranty / comeback; towing intake; bays and technician skills; photos; promised-completion time on Today; workshop-system connection |
| 2 | Beauty & Salon | Clients; memberships; preferences with patch test; colour cards (formula, developer, processing time); deposits, no-show fees and gift cards in Money; check-ins and waitlist | Multi-service bookings with processing gaps; stylist / chair booking and utilization; rebooking-due list; retail purchases; colour cards limited to stylists |
| 3 | Childcare | Children with private allergies, pick-ups and custody notes; incident reports; enrolments linked to a child; never confirms a child to a caller; transcripts never open to staff | Guardians as separate contacts; consents, medication authorizations and immunization records; room capacity and staffing ratios; secure attendance check-in / out of children; authenticated pickup-change process; expiring-document alerts |
| 4 | Cleaning Services | Properties: rooms, checklist, supplies, private key / lockbox / alarm codes. Visits linked to a property, with arrival window and team. Plans with frequency. Dispatch on; no check-ins. | Recurring visit generation; checklist completion per visit; route planning; crew time; damage and re-clean records; photos; access revoked automatically on reassignment (today access ends when the job closes) |
| 5 | Dental | Treatment plans (proposed → accepted / declined → scheduled → completed) with chase; insurance coverage with private member ID; new-patient forms; recalls with interval; check-ins and waitlist | Guardians; preauthorization status; hygienist / dentist / chair scheduling; recalls-due card on Today; practice-management connection |
| 6 | E-commerce | Orders, returns (label sent, refund amount), support cases; no bookings, check-ins or waitlist; never invents status | **Store connection** (order lookup); order items, products, shipments, tracking; customer verification before changes; refund requested vs completed; chargebacks; helpdesk connection |
| 7 | Education | Applications (with guardian fields) linked to courses; courses; class sessions with places; session bookings with waitlist and attendance | Guardians as separate contacts; tuition and instalments (Money covers single invoices only); term calendar, make-ups, substitutions; accommodations as private fields; separate tutoring, training and school modes |
| 8 | Electrical | Jobs linked to sites, with arrival window; sites with private access and panel size; permits with inspection result; maintenance plans | Equipment on sites; technician qualifications; change orders; photos; certificates |
| 9 | Financial Services | Opportunities; service requests with document checklist; annual reviews; no-advice line; transcripts never open to staff | Households and authorized representatives; identity-verification status; complaints; separate modes per service (accounting, lending, advice) |
| 10 | Fitness | Memberships (waiver, PT sessions left); trials; classes with places; bookings with concurrency-safe waitlist; freeze / cancellation requests (requested ≠ approved) | Automatic waitlist promotion when a place frees; member check-in history; class packs; expiring-membership and failed-payment cards; access-control connection |
| 11 | Healthcare | Referrals; refill requests (request ≠ approval); prior authorizations with private number; results callbacks (never by the AI); coverage; identity-check and no-results lines | Guardians / proxies; forms; clinician availability; EHR connection. **A BAA with voice and SMS providers is needed before real patient calls.** |
| 12 | Home Services | Properties with private access; jobs with skill, arrival window and property link; service plans | Equipment / assets; change orders; photos; callbacks |
| 13 | Hospitality | Stays (arrival time, special requests); guest requests; group enquiries; room types (the AI quotes only these); lost and found; check-ins | **Live availability (PMS connection)**; room inventory conflicts; deposits on reservations; housekeeping status; hotel vs short-stay modes |
| 14 | HVAC | Equipment (make, model, serial, refrigerant, filter size) linked to properties; jobs; service agreements; private property access | Warranty claims; parts; replacement-lead flag by age; photos |
| 15 | Insurance | Policies (carrier, line, number, premium, dates) with renewal task; claims from first notice with chase; quotes; policy requests; never binds or promises cover | Insured assets; documents; endorsements; authorized contacts; agency-system connection |
| 16 | Landscaping | Properties (lot, grass, irrigation, private gate access); jobs with weather delay; plans with seasonal add-on | Areas and measurements; materials; routes; project phases; chemical application records (they exist for pest control) |
| 17 | Legal | Matters with opposing and related parties, practice area, jurisdiction, incident and limitation dates, engagement letter, consultation fee; deadlines with 30 / 7 / 1-day tasks; document requests; never confirms who is a client | Conflict search across parties (data is captured, not searched); declined engagements and referrals; retainer and trust tracking (specialist system) |
| 18 | Other | Generic enquiries and records; every capability optional | Owner-chosen modes at setup |
| 19 | Pest Control | Properties with history, safety notes and private access; jobs; application records (product, EPA number, amount, location, applicator, date: required); bond renewal | Inspections and treatment plans; consent before treatment; preparation instructions; re-treatment / warranty records; jurisdiction-specific fields |
| 20 | Pet Care & Vet | Pets (species, breed, weight, sex, microchip, allergies, alerts, vaccines due, passed away); reminders and boarding linked to the pet; no-dosing line | **Appointments linked to the pet**; boarding capacity; separate vet / grooming / boarding / walking / daycare modes; authorized contacts |
| 21 | Photography & Events | Bookings (contract, balance due, second shooter, shot list); galleries linked to bookings; deposits in Money | Availability check against booked dates; crew and equipment; milestones and revisions; rights / consent documents |
| 22 | Plumbing | Jobs (arrival window, property link, permit, inspection, warranty); properties (water heater, private access); plans | Photos; parts; return visits |
| 23 | Professional Services | Opportunities (proposal amount and status); projects (retainer value, hours used) | Stakeholders; deliverables and milestones as records; time tracking; scope changes; agency vs consultancy modes |
| 24 | Property Management | Units (owner, rent, private keys); vendors (insurance expiry task); requests linked to unit and vendor, with emergency flag; leases; rental applications | Owners and tenants as separate contact kinds and logins; inspections; cost allocation; emergency acknowledgement and fallback chain; fair-housing review step |
| 25 | Real Estate | Requirements (pre-approval); properties; viewings; deals with inspection, appraisal, finance and closing dates; open houses; seller leads | Open-house sign-ins becoming leads automatically; offers; listing / MLS connection |
| 26 | Restaurant | Reservations with party size; tables; walk-in waitlist; special requests (allergies, occasion); events (deposit, minimum spend); catering orders; check-ins; no allergen guarantees | Table combinations and seating durations; expected covers on Today; table status; POS connection |
| 27 | Spa & Wellness | Packages; memberships; intake with private health notes, pressure and therapist preference; gift cards in Money | Rooms and equipment with buffers; package balances deducted per visit; missing-intake card on Today |
| 28 | Travel | Trips (insurance offered / accepted, visas, deposit and final payment dates); bookings with supplier; traveler documents (private passport number, expiry task) | Groups with several travelers; itineraries; supplier confirmations; disruptions; GDS / supplier connection |

## Cross-industry rules from the spec

**Scheduling models**

| Model | Status |
|---|---|
| Individual appointment | ✅ |
| Arrival window and dispatch | 🟡 window field and dispatch capability; no board, routes or "on the way" text |
| Capacity-based class | ✅ records with concurrency-safe capacity; no auto-promotion |
| Table / party allocation | 🟡 party size and tables; no combinations or durations |
| Multi-night inventory | 🟡 stays and boarding dates; no inventory conflicts |
| Multi-resource event / project | ❌ |
| Request queue without booking | ✅ |
| Mixed model | ✅ capabilities can be mixed |

**Financial meanings**

| Distinction | Status |
|---|---|
| Quote issued vs accepted | ✅ |
| Deposit requested vs received | ✅ |
| Invoice issued vs paid | ✅ |
| Refund requested vs completed | 🟡 only completed refunds are recorded |
| Gift card value vs cash payment | ✅ |
| Coverage information vs verified benefits | 🟡 a verification date, no benefits check |
| Entitlement vs payment | ✅ kept in separate records |

**Permission boundaries**

| Boundary | Status |
|---|---|
| Staff vs managers | ✅ |
| Assigned vs unassigned staff | ✅ for private fields; ❌ for whole records |
| One location vs several | ❌ |
| Family / guardian / proxy access | ❌ |
| Contractors and vendors | ❌ |
| Restricted platform support | ✅ read-only admin role |
| Recording / transcript access | ✅ |
| Export and bulk download | 🟡 owner / admin, per customer |
| Access after termination, reassignment or suspension | 🟡 removal ends access; suspended businesses' access is still an open decision |

**Success chain** (request → record → owner → action → customer update → audit → recovery)

- Record, owner, action, audit and recovery: ✅.
- **Customer update: ❌ for most workflows.** Texts and emails are switched off until you approve going live; there's no "on the way" text.

## Suggested order (follows the owner's priorities)

1. **Approve and apply** the 10 migrations from 4 November. Privacy, navigation, Today, links and money then reach customers.
2. **Connected records, part two.**
   - Appointments linked to a record (pet, vehicle, property, class).
   - Photos on records.
   - Guardians and authorized contacts as their own records, with roles.
3. **Scheduling models.**
   - Dispatch board (technician by day, arrival windows, "on the way" text once messaging is live).
   - Resources (chair, room, bay) with buffers.
   - Automatic waitlist promotion for classes.
4. **Owner control.**
   - Locations, with staff limited to theirs.
   - Refund-requested state.
   - Industry-specific Today cards (recalls due, arrivals and departures, ready for pickup).
5. **Integrations.** Each needs a provider choice and your approval:
   - store (Shopify / WooCommerce);
   - hotel PMS;
   - workshop / field-service;
   - practice management / EHR;
   - accounting.
6. **Portals** for guardians, tenants, owners and vendors (largest effort; separate security review).
