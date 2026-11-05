# Existing businesses: settings migration preview (5 Nov 2026)

`sql/zella_setup_enforcement.sql` (applied 5 Nov) makes **new** setup saves reach the live settings. Businesses set up
before it keep stale live settings until setup is saved again. `sql/zella_config_migration.sql` (not applied) adds:
- `zella_config_migration_preview(business)`: what is live now, what would be live, and why;
- `zella_config_migration_apply(business)`: takes a snapshot, applies, and notifies the owners;
- `zella_config_migration_restore(snapshot)`: undoes it exactly.

All three are server-only.

## Source precedence

The first source that is set wins, and a later source never overwrites an earlier one.

| Setting | Precedence |
| --- | --- |
| Language and greeting | Settings > Languages (the owner's own choice; kept) > setup answers |
| Transfer number | admin call routing (kept) > setup receptionist transfer phone > setup integrations transfer number > owner's phone (type "owner") |
| Setup knowledge (FAQs, policies, about, service area, details) | the current setup answers. Owner-added Knowledge items are never touched |
| Booking rules, booking abilities, handover reasons | already read live from the saved setup (no migration needed); shown so nothing is assumed |
| Messages saved as "AI call" | held for the owner (`zella_channel_review.sql`); the preview lists them as `owner_decides` |

Validation is the same as the owner's own save: language catalogue, greeting rules, and phone numbers in E.164.
A business whose setup value fails is reported as `needs_fix` and left unchanged. It still counts as stale, so it is
never silently left on old settings without a flag.

## Production, read only (5 Nov 2026, after the apply)

These are current configuration values. They say nothing about what was set before today. No customer data was read,
and phone numbers are not shown.

| Business | Status | Language: live → proposed | Setup knowledge: live / setup | Transfer number | Handover reasons | Booking rules saved | Stale |
| --- | --- | --- | --- | --- | --- | --- | --- |
| test saloon (0ed3b097) | testing | none → en-US + Spanish, setup greeting (`apply_setup`) | 0 / 0 | setup number available, no live transfer_number (`apply_setup`) | saved: asks for a person, can't answer, upset, emergency | can_book true, reschedule, cancel | yes |
| hawkye cafe (4478f7be) | automation_setup | none → en-US, setup greeting (`apply_setup`) | 0 / 0 | setup number available (`apply_setup`) | saved: same four | can_book **false** (enforced since 5 Nov), reschedule, cancel | yes |
| ftyuyguygiug (1621a679) | business_info | nothing set | 0 / 0 | none | not saved | none | no |
| Roohani Cafe (b8f0d92f) | business_info | nothing set | 0 / 0 | none | not saved | none | no |

What would change if the migration were applied:
- **Both stale businesses:**
  - The assistant would greet with the setup greeting. The test saloon would also accept Spanish.
  - Transfers would go to the setup number. `zella_transfer_destination` already falls back to the receptionist
    step's phone, so this changes nothing where that phone is set. It matters where the number came from the
    integrations step or the owner's phone.
- **After `sql/zella_escalation_rules.sql` (not a migration):**
  - Both stale businesses already saved reasons, so transfers become limited to those three reasons. That matches
    today's prompt rule, except that "can't help" becomes "can't answer".
  - A transfer is only connected after the server approves it.
  - The two businesses without saved reasons keep today's behaviour.
- No business has messages saved as "AI call" (0 reviews) and none has setup knowledge to sync.

## Recovery

Each apply records a snapshot: the languages row, the call-routing settings, and every setup knowledge item's text and
status. The restore puts all three back. Items the apply created are archived, never deleted.

Tested (`tests/config_migration/run.sh`, isolated): the preview taken after a restore is identical to the one taken
before applying, for all seven test businesses.

## Tests

`tests/config_migration/run.sh` uses seven businesses recreated in the pre-fix state:
- setup language with no live settings;
- an owner's own language choice, which is kept;
- a greeting containing a link, which is `needs_fix`, not applied, and still reported;
- setup FAQs not answerable, which become answerable;
- an admin routing number, which is kept;
- the owner's phone used by precedence;
- a business that is up to date and not flagged.

After applying, the only stale business left is the one with an invalid greeting. Owners are notified of what changed,
and the restore is exact.

## To run it in production (needs approval; not done)

1. Apply `sql/zella_config_migration.sql`.
2. Run `select public.zella_config_migration_preview()` and review it against the table above.
3. For each stale business, run `select public.zella_config_migration_apply('<id>')`, keeping each `snapshot_id`.
4. Check again: the preview should show no stale business except any `needs_fix`, which needs the owner.
5. Undo with `select public.zella_config_migration_restore('<snapshot_id>')`.

This replaces the "one-time catch-up" comment in `sql/zella_setup_enforcement.sql`.
