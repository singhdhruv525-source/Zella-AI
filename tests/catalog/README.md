# Catalog drift test (PLT-08)

`web/supabase/functions/_shared/catalog.json` is the one shared list of:

- **audit actions** (`audit_actions`, each with the label people read), plus `audit_action_prefixes` for names built
  at run time (`'attendance.' || p_action`, `"legal." + r.to`); every name such a prefix makes is listed too;
- **platform alert kinds** (`alert_kinds`, `alert_kind_prefixes`);
- **admin permissions** (`permissions`; `owner_only_permissions` are the two only a Zella Voice owner holds).

`drift_test.mjs` reads every SQL file under `sql/`, every edge function module under `web/supabase/functions/`
(a new module file is read without being listed), the n8n code nodes in `n8n/src/` and the web app in `web/src/`, and
fails when:

- something writes or checks a name that is not in the list, or builds one at run time from an undeclared prefix;
- a name can't be worked out (an audit insert whose action is neither a literal, a `case`, a variable set from
  literals nor a parameter of a function whose callers pass literals);
- a name in the list is no longer used anywhere, or has no label, or a label has a dash;
- `settings.ts` `PERMISSION_CATALOG` (the role editor's list) differs from `permissions`;
- a label key in `web/src/ownerFormat.js` `ACTION_LABELS` is not a real audit action.

Run it with `npm run lint` in `web/` (which also runs the unit tests), or directly:

```sh
node tests/catalog/drift_test.mjs          # check
node tests/catalog/drift_test.mjs --list   # print every use found, with file and line
node --test tests/catalog/scan.test.mjs    # unit tests for the scanner
```

When you add an audit action, alert kind or permission, add it to `catalog.json` in the same pull request. Keep each
list sorted, so two pull requests adding names never change the same line. There is no CI yet (an owner decision),
so the test runs locally through `npm run lint`.
