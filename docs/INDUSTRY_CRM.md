# Zella industry CRM

One shared record system. Each business gets its industry's starting record types the first time its CRM opens (`zella_ensure_crm_types`). After that the business owns its settings: owners and managers can rename records, change statuses, add fields, hide types or add new ones under **Customise records**. Presets never overwrite a business's own changes. Records are isolated per business by Row Level Security; every write goes through a checked function.

Safety built in: records only hold the fields configured for them; unique fields (for example a vehicle registration) block duplicates; the AI receptionist (`zella_ai_save_record`) never overwrites. A possible duplicate becomes a task for a person. Dental, healthcare, legal, financial, education and fitness types carry a visible note and hold administrative information only.

| Industry | Record types |
|---|---|
| Automotive | Vehicles, Repair orders |
| Beauty Salon | Memberships, Service preferences |
| Dental | Recalls, Enquiries |
| Ecommerce | Orders, Returns, Support cases |
| Education | Applications, Courses |
| Electrical | Jobs, Sites |
| Financial Services | Opportunities, Service requests |
| Fitness | Memberships, Trials and enquiries |
| Healthcare | Referrals, Administrative enquiries |
| Home Services | Properties, Jobs, Service plans |
| Hvac | Equipment, Jobs, Service agreements |
| Legal | Matters, Document requests |
| Other | Enquiries, Records |
| Plumbing | Jobs, Properties, Maintenance plans |
| Professional Services | Opportunities, Projects |
| Real Estate | Requirements, Properties, Viewings, Deals |
| Restaurant | Events and catering, Special requests |
| Travel | Trips, Bookings |
| Hospitality | Stays, Guest requests, Group and event enquiries |

Industries are matched by the name of the business's industry (for example "Real Estate" or "Beauty & Salon"). An industry that matches nothing gets the general "Other" set.

Not built here: staff assignment on records (use the text field for now), and syncing with outside systems (listings, booking, store platforms). Those stay the source of truth.
