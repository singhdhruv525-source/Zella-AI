# What each industry's CRM needs: an owner's-eye review, 2026-11-04

## How this was done

**Test setup.** One test business was set up for each of the 28 industries on the isolated test database (test data only). Every CRM page was opened as its owner in a real browser: 876 page loads, using `tests/browser/industry-review.cjs`.

**Technical result.**
- 0 crashes, 0 failed calls and 0 accessibility violations.
- One loading bug, fixed: "Customize records" showed "Nothing to customize yet" for about a second before the record types arrived.

**Every industry gets today:**
- **The same core pages:** Today, Calendar, Check-ins, Waitlist, Tasks, Leads, the customer list, Calls & messages (8 pages), AI Receptionist, Knowledge, Automations, Lead sources, Reviews, Reports, Team, Scorecards, Access, Approvals, Security log, Integrations and Settings.
- **The same ten modules.**
- **Its own words:** for example Patients, Service calls, Stylists.
- **Its own record types:** for example Recalls, Repair orders, Matters.
- **Its own automation rules:** 7–10 per industry.
- **Its own setup questions.**

**What's missing** is everything below. I wrote it as the owner of each kind of business would see it: what they track, what callers ask for, and what's regulated. Each industry has three parts:

- **Must** — the CRM feels wrong for that business without it.
- **Should** — clearly valuable.
- **AI receptionist** — what the phone agent must know or never do.

## Changes that help every industry

1. **Show only the pages a business uses.** Check-ins and Waitlist are front-desk pages.
   - Plumbers, electricians, HVAC, pest control, landscapers, cleaners, e-commerce shops, insurance, legal, travel, property managers and real estate agents don't have walk-in arrivals.
   - E-commerce takes no appointments at all, yet Today says "No order support requests today. Book one with New order support."
   - The data model already has a place for this: `industry_configurations.features` is empty for all 28 industries. A per-industry list of hidden pages there would fix it.
2. **Put the industry's own records on Today.**
   - Today shows appointments and calls for everyone.
   - A dental owner's morning starts with *recalls due*, a plumber's with *jobs to dispatch*, a property manager's with *open maintenance requests*.
3. **Link records to appointments and customers in both directions.**
   - Industry records link to a person (`link_person`), but not to an appointment or to each other.
   - Examples: a vehicle and its repair orders, a pet and its visits, a property and its jobs.
4. **Deposits, estimates and invoices.**
   - Several industries live on deposits (photography, salons, restaurants with large parties) or quotes (all trades). Today these are only text fields.
   - A simple "amount / due / paid" status on bookings and jobs, before full billing, would cover most of it.
5. **Privacy by role** (open decision M-4). Transcripts and recordings are readable by every member role. That is not acceptable for healthcare, dental, vet, legal, financial services, insurance and childcare. Those industries should default to managers and above.
6. **Customer profile fields per industry.** The customer list is generic. Each industry needs 3–6 fields on the person itself, for example:
   - dental: insurance carrier and member ID;
   - salon: colour formula;
   - childcare: authorized pick-ups.

---

## Health and care

### Dental (Patients, Providers; today: Recalls, Enquiries)
- **Must**
  - **Treatment plans** (proposed treatment, estimate, insurance estimate; presented → accepted → scheduled → declined). Case acceptance is the biggest revenue lever in a dental office, and nothing tracks it today.
  - **Insurance on the patient:** carrier, member ID, subscriber, last verification date.
  - **New-patient forms status.**
- **Should**
  - Recall interval per patient (6 or 12 months).
  - Hygiene versus doctor appointment types with different lengths.
  - Last X-ray date.
  - A no-show count shown on the patient.
- **AI receptionist**
  - Book cleanings and new-patient exams.
  - Triage dental emergencies (swelling, trauma, bleeding: same day or the on-call dentist).
  - Never give clinical advice.
  - Never read out balances or treatment details to an unverified caller.
- **Hide:** Waitlist, unless they use a short-notice list (keep it; dentists do fill cancellations). Keep Check-ins.

### Healthcare (Patients, Providers; today: Referrals, Administrative enquiries)
- **Must**
  - **Prescription refill requests** (medication, pharmacy, prescriber; sent to provider → approved / denied). This is the most common call a clinic gets.
  - **Insurance and eligibility** on the patient.
  - **Prior authorizations** (procedure, payer, submitted, approved / denied, expiry).
- **Should**
  - Test results callback requests, routed to a nurse and never read out by AI.
  - Forms and records-release requests.
  - Telehealth versus in-person visit type.
- **AI receptionist**
  - Emergency script ("if this is an emergency, hang up and dial 911").
  - No medical advice.
  - Identity check before discussing anything.
  - A BAA with the voice and SMS providers before going live.
  - No health details in texts.

### Pet care & veterinary (Pet owners; today: Pets, Reminders)
- **Must**
  - **Pet profile:**
    - species and breed exist;
    - add weight, sex and neutered;
    - add microchip, allergies and alerts (for example "bites");
    - add the vaccine due dates themselves, rather than a separate reminder record only.
  - **Appointments linked to the pet**, not only the owner.
- **Should**
  - **Boarding stays** (check-in and check-out, kennel, feeding notes, medication).
  - **Grooming notes** (cut style, behaviour).
  - Patients who have died marked, so reminders stop. This is very important for owner trust.
- **AI receptionist**
  - Emergency triage: poisoning, breathing, trauma → come in now or go to the emergency clinic.
  - Book vaccines.
  - Never give dosing advice.

### Spa & wellness (Clients, Therapists; today: Packages, Memberships)
- **Must**
  - **Client intake and health form:**
    - contraindications: pregnancy, allergies, recent surgery, blood pressure;
    - pressure preference;
    - date signed.
  - **Gift cards and vouchers** (code, value, balance, expiry).
- **Should**
  - Room or resource booking (couples room, sauna).
  - Therapist gender preference.
  - Add-ons.
  - A cancellation-fee flag.
- **AI receptionist**
  - Sell packages and gift cards.
  - Explain the cancellation policy.
  - Ask about pregnancy when booking certain treatments.

### Fitness (Members, Trainers; today: Memberships, Trials)
- **Must**
  - **Classes:** a schedule, capacity and a class booking list, with a waitlist per class. Gyms book classes, not one-to-one appointments.
  - **Attendance and check-in history** per member. Check-ins is exactly right here; keep it and make it member-based.
  - **Freeze and cancellation requests** (dates, reason, notice period).
- **Should**
  - PT session packs (sessions left).
  - Waiver signed.
  - Payment failed or dunning status.
  - At-risk members (no visit in 14 days).
- **AI receptionist**
  - Book trials and classes.
  - Explain membership options.
  - Take cancellation requests per the policy, without arguing.

### Beauty & salon (Clients, Stylists; today: Memberships, Service preferences)
- **Must**
  - **Client colour and formula card** (formula, developer, processing time, date, stylist). This is the single most-used record in a salon.
  - **Deposits and no-show fees** (amount, taken / forfeited).
  - **Patch test date** for colour and lash services.
- **Should**
  - Gift cards.
  - Retail product purchases (for rebooking prompts).
  - Before-and-after photos.
  - Preferred stylist enforced in booking.
- **AI receptionist**
  - Match service length to the stylist (a colour plus cut is 2.5 hours).
  - Take deposits via a link.
  - Offer the waitlist.

---

## Trades and field services

All seven of these share the same structure: **jobs at the customer's address, dispatch, estimates, technicians in vans**.

**For all of them:**
- **Hide** Check-ins and Waitlist.
- **Rename** Calendar to "Schedule / Dispatch", with a technician-by-day view.
- **Must**
  - Job **photos**.
  - **Estimate and invoice amounts with paid status.**
  - **Arrival window** ("8–12"), not a fixed time.
  - A **"technician on the way"** text.
- **AI receptionist**
  - Emergency triage per trade (gas smell, flooding, sparking, no heat in freezing weather: dispatch or tell the caller who to call now).
  - Quote the call-out fee.
  - Collect the address, gate code, pets on site and photos by text.

### Plumbing (today: Jobs, Properties, Maintenance plans)
- **Must**
  - Water heater and fixture details on the property (type, age, last flush).
  - Permit needed / inspection date on larger jobs.
- **Should**
  - Warranty on parts and labour, per job.
  - Drain-cleaning repeat customers flagged.

### HVAC (today: Equipment, Jobs, Service agreements)

This is the most complete industry preset.
- **Must**
  - Equipment linked to the **property** (equipment has an address text field today; make it a link).
  - Refrigerant type.
  - Filter size, for maintenance visits.
- **Should**
  - Seasonal tune-up campaigns (exists as an automation).
  - Replacement-quote opportunities for systems over 12 years old.

### Electrical (today: Jobs, Sites)
- **Must**
  - **Permits and inspections** (permit number, inspection date, passed / failed). Electrical work is permit-heavy.
  - **Maintenance plans or agreements**: missing, while plumbing and HVAC have them.
- **Should**
  - Panel and service size on the site.
  - Generator and EV charger installs as job types.

### Home services (Home services and Cleaning services share one preset: Properties, Jobs, Service plans)
- **Cleaning-specific must**
  - **Checklist per property** (rooms, special instructions).
  - **Key, lockbox and alarm codes**, stored safely and shown only to the assigned team.
  - **Recurring frequency** (weekly / biweekly) feeding the schedule.
  - **Supplies brought or provided.**
- **Home services should**
  - Job category drives the technician skill (handyman, appliance, garage door). Cleaning and home services probably deserve **separate presets**.

### Landscaping & lawn care (today: Jobs, Maintenance plans)
- **Must**
  - A **property record** (lot size, grass type, gate, irrigation), so visits and jobs repeat against it. It exists for plumbing but not here.
  - **Weather delays** (rain-out → reschedule all of today's route).
- **Should**
  - Seasonal services (aeration, leaf clean-up, snow removal) as plan add-ons.
  - Chemical applications (see pest control).

### Pest control (today: Jobs, Service plans)
- **Must**
  - **Pesticide application records:** product, EPA registration number, amount, target pest, location and applicator license. Most US states require these to be kept.
  - A **property record** with infestation history.
  - **Safety notes:** children, pets, fish tanks.
- **Should**
  - Termite bonds and warranties (start, renewal, inspection due).
  - Follow-up visit included / chargeable.

### Automotive (Customers, Service advisors; today: Vehicles, Repair orders)
- **Must**
  - **VIN and plate state** on the vehicle. US shops look up by VIN; "Registration" is a UK term.
  - Repair orders **linked to the vehicle record** (it's a text field today).
  - **Loaner and courtesy car booking:** the setup question exists, but nothing tracks the cars.
- **Should**
  - Recall check per VIN.
  - Declined-work reminders ("brakes at 3mm, declined", then remind in 60 days). This is big repeat revenue.
  - Labour and parts lines on the estimate.
- **AI receptionist**
  - Status calls ("is my car ready?"), read from the repair order status.
  - Book drop-off versus wait.
  - Never give a price without an inspection, apart from a published price list.
- **Check-ins:** keep (vehicle drop-off). Waitlist: hide.

---

## Property and real estate

### Property management (Tenants; today: Maintenance requests, Leases)
- **Must**
  - **Units and properties** (owner, address, unit, occupancy, rent). Requests and leases only have a free-text "unit".
  - **Emergency maintenance triage** (flood, no heat, gas, lockout → on-call vendor now). The setup question exists; the routing should use it.
  - **Vendors** (company, trade, insurance expiry, phone), with jobs assigned to vendors rather than staff.
- **Should**
  - **Leasing pipeline:** prospects → showings → applications → approved. Today "appointments" are called Viewings, but nothing tracks applications.
  - Rent questions routed to the portal; the AI never discusses balances.
  - Move-in and move-out inspections.
  - Owners as a second kind of contact.
- **Hide:** Check-ins, Waitlist.

### Real estate (Clients, Agents; today: Requirements, Properties, Viewings, Deals)

This is the most complete preset.
- **Must**
  - **Open houses** (property, time, sign-ins captured as leads).
  - **Seller and listing leads** (address, valuation request, motivation) apart from buyer requirements.
- **Should**
  - Showing feedback sent to the seller.
  - Pre-approval status on buyers.
  - Contract milestones (inspection, appraisal, financing and closing dates) with automatic reminders.
- **Hide:** Check-ins, Waitlist.

---

## Professional services

### Legal (Clients, Attorneys; today: Matters, Document requests)
- **Must**
  - **Conflict check data:** opposing parties and related parties on intake. "Conflict checked" is only a yes/no today, so the check itself can't be run.
  - **Statute of limitations / critical deadlines** per matter with escalation. A "key date" exists, but a missed limitation date is malpractice, so it needs 30/7/1-day reminders to the responsible attorney.
  - **Intake screening** (practice area, jurisdiction, incident date, how they heard).
- **Should**
  - Retainer or engagement letter sent / signed.
  - Consultation fee paid.
  - Court dates as calendar items.
- **AI receptionist**
  - Never give legal advice.
  - Never confirm whether someone is a client to a third party.
  - Take intake only.
  - Transcripts: attorneys and managers only.
- **Hide:** Check-ins (keep only if they see walk-ins), Waitlist.

### Financial services (Clients, Advisors; today: Opportunities, Service requests)
- **Must**
  - **Annual review due** per client (the automation exists; the date should live on the client).
  - **Document checklist** per request (tax returns, IDs, statements).
  - **Compliance:** call recording retention (FINRA / SEC books and records) and no investment advice by the AI.
- **Should**
  - Household (spouse, dependants).
  - Accounts and products held.
  - Tax season capacity for accountants.
- **Hide:** Check-ins, Waitlist.

### Insurance (Clients, Advisors; today: the Financial services preset)

This is the biggest gap of any industry. Insurance has **no records of its own**.
- **Must**
  - **Policies** (carrier, line such as auto, home, life or commercial, policy number, premium, effective and expiry dates). Expiry drives the renewal automation that already exists.
  - **Claims / first notice of loss** (date of loss, what happened, claim number, adjuster, status). After-hours claim calls are the main reason an agency wants an AI receptionist.
  - **Quotes** (line, carriers quoted, premium, status).
- **Should**
  - Certificates of insurance requests (commercial clients ask for these daily).
  - Payment and cancellation-for-non-payment notices.
- **AI receptionist**
  - Take first notice of loss 24/7.
  - Never bind coverage or promise a claim will be covered.
- **Hide:** Check-ins, Waitlist.

### Professional services (Clients, Consultants; today: Opportunities, Projects)
- **Must**
  - Proposals with amount and status (a text field today).
  - **Retainer or engagement value.**
- **Should**
  - Time or hours used against a retainer.
  - Project milestones with client-visible updates.
- **Hide:** Check-ins, Waitlist.

---

## Hospitality, food, events and travel

### Restaurant (Guests; today: Events and catering, Special requests, Walk-in waitlist, Tables)

This is strong already.
- **Must**
  - **Reservation details on the booking itself:** party size, table or area, occasion, allergies.
  - **Guest profile:** allergies, dietary needs, VIP, regular, no-show count.
  - **Deposits** for large parties (the setup question exists) and **catering orders** with headcount, menu and pickup or delivery.
- **Should**
  - Table turn times.
  - Private dining minimum spend.
  - Takeout order callbacks.
  - "86'd" items the AI must not offer today.
- **AI receptionist**
  - Book within capacity and largest-party rules.
  - Repeat allergies back.
  - Hours, menu and parking.
- **Hide:** Team scorecards (rarely relevant). Keep Check-ins (arrivals) and Waitlist.

### Hospitality (Guests; today: Stays, Guest requests, Group enquiries)
- **Must**
  - **Room types and rates** (or a PMS link), so the AI can answer availability and price questions without making things up.
  - Pre-arrival details: arrival time, special requests, ID and card on file.
  - Lost and found.
- **Should**
  - Upsells (late checkout, early check-in, parking).
  - Group room blocks.
  - Housekeeping requests feeding Guest requests (exists).
- **Check-ins:** keep (guest arrivals).

### Photography & events (Clients, Photographers; today: Bookings)
- **Must**
  - **Contract and deposit:**
    - contract sent / signed;
    - deposit paid;
    - balance due date.
  - **Shot list and timeline** per event; second shooter.
  - **Gallery delivery** (link, delivered on, expiry).
- **Should**
  - Venue contacts.
  - Package and add-ons (album, prints).
  - Booking inquiry date-availability checks against booked dates.
- **Hide:** Check-ins, Waitlist.

### Travel (Travelers, Travel advisors; today: Trips, Bookings)
- **Must**
  - **Traveler documents:** passport number and expiry. A passport within 6 months of expiry needs an alert.
  - Visas needed.
  - Travel insurance offered / accepted (a liability point for agencies).
  - **Payment schedule** (deposit, final payment due) per trip. "Payment due" exists only per booking today.
- **Should**
  - Supplier commissions.
  - Traveler preferences (seat, diet, loyalty numbers).
  - Emergency contact while abroad.
- **Hide:** Check-ins, Waitlist.

---

## Education and childcare

### Childcare (Parents; today: Enrolments)
- **Must**
  - **Child profiles:**
    - name and date of birth;
    - **allergies and medical needs**;
    - **authorized pick-up people**;
    - custody notes;
    - immunization records.
  - **The AI must never confirm anything about a child to an unknown caller.**
  - **Daily attendance**: Check-ins fits, but for children, not tours.
  - Tuition and fees (amount, due, paid, subsidy).
- **Should**
  - Classroom or age group capacity (ratios).
  - Incident reports.
  - Waitlist by start date. This waitlist is the business's lifeblood; the Enrolments waitlist exists, so make it the main one.
- **Privacy:** staff see the children of their own room only; transcripts are restricted.

### Education (Students, Instructors; today: Applications, Courses)
- **Must**
  - **Class sessions and attendance** (course, date, present / absent).
  - **Fees and instalments** (amount, due, paid).
  - **Guardian** as a separate contact for minors (today only fields on the application).
- **Should**
  - Course capacity and waitlist (Courses has seats; link applications to them).
  - Certificates issued.
  - Online versus in-person.
- **AI receptionist**
  - Course info and intakes.
  - Book counselling sessions.
  - Never discuss a minor's information with anyone but the guardian.

---

## Retail

### E-commerce (Customers, Support agents; today: Orders, Returns, Support cases)
- **Must**
  - **Store connection for order lookup** (Shopify / WooCommerce). Without it the AI can't answer "where is my order?", the number one question. Today the setup only asks how customers check an order.
  - **No appointments:** hide Calendar, Check-ins, Waitlist and the "New appointment" button.
  - Today should show open cases, returns waiting and orders with issues.
- **Should**
  - Returns label sent.
  - Refund amount.
  - Product questions answered from the catalog (Knowledge).
  - Cart-abandonment follow-up (consent rules apply).

## Other (general preset: Enquiries, Records)
Keep it generic. The setup wizard should suggest the closest specific industry first.

---

## Suggested order of work

1. **Per-industry page visibility.** `industry_configurations.features`, then hide Check-ins, Waitlist and Calendar where they don't fit; e-commerce first. This is one small server function change plus the menu builder; there are no new tables.
2. **Industry records on Today** (counts and lists from the record types each industry already has).
3. **New record types and fields**, as preset updates (`industry_crm_presets`). New businesses get them; existing ones through `zella_ensure_crm_types` without overwriting their own changes. Highest value first:
   - Insurance: Policies, Claims, Quotes.
   - Dental: Treatment plans and insurance fields.
   - Healthcare: Refill requests and Prior authorizations.
   - Childcare: Children with authorized pick-ups and allergies.
   - Property management: Units and Vendors.
   - Pest control: Application records.
   - Automotive: VIN and vehicle links.
   - Fitness: Classes.
   - Salon: Colour cards.
   - Split cleaning from home services.
4. **Record ↔ record and record ↔ appointment links** (vehicle ↔ repair order, pet ↔ appointment, property ↔ job).
5. **Privacy defaults per industry** (transcripts and recordings), once you decide M-4.
6. **Money basics:** deposit, estimate and invoice amounts with paid status.
7. **AI receptionist rules per industry** (emergency triage, no-advice lines, identity checks), in each industry's receptionist prompt.
