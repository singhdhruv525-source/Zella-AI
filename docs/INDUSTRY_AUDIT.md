# Industry audit (October 2026)

Checked: 28 industries, their record types, 158 industry rules, terminology, AI safety wording and front-end defaults.

## Fixed (live in the database and saved in `sql/zella_industry_fixes.sql`)
| Problem | Effect | Fix |
|---|---|---|
| Nothing ever filled a record's due date (`due_at`) | All 21 "reminder before a date" rules never fired | Reminders now read a date field on the record (`due_field`); date-only fields mean noon in the business's time zone |
| Two reminders targeted a closed status (childcare "enrolled", finance "won") | Could never fire | Childcare allowed through with `include_closed`; finance reminder moved to service requests (renewal date) |
| Plumbing emergency rule looked for `priority`, the type has `urgency` | Never fired | Corrected to `urgency` |
| Electrical emergency compared "emergency" with "Emergency" | Never fired | Comparison ignores capital letters |
| HVAC had no emergency rule | No alert for no-heat / no-cooling jobs | Added "Emergency intake" |
| Legal text said "We have accepted your matter" | Reveals a client relationship by SMS | Neutral wording |
| AI safety wording only covered a few industries | No guard rails for allergies, injuries, repair promises, fares, admissions, prices | Added for restaurant, hospitality, fitness, property management, travel, education, photography |

All checked with rolled-back tests (childcare reminder fires once, not twice; plumbing emergency raises an urgent alert).

## Still missing (not built)
- **Restaurant:** table tracking, walk-in waitlist with party size and quoted wait, "we're full tonight" setting for the AI, reservation no-show rule.
- **Every industry has the same 10 modules.** No industry-specific modules (for example class schedules for fitness, quotes and dispatch for trades).
- **No starter services or FAQs per industry** were found, so each business starts with an empty knowledge base.
- **Healthcare, dental, childcare, legal:** before real customers use them, confirm consent wording for texts and whether a business-associate agreement is needed with the messaging and AI providers.
- The 4 checklist items that need real accounts (41, 50, 125, 263).

## Notes
- Date-only fields are treated as noon local time, so "24 hours before" lands at noon the day before.
- Record types are copied to a business once and never overwritten. A business set up before a preset changed keeps the old record types. Use "Industry configuration" to refresh.
