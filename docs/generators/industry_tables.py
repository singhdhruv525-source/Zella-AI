# Prints the per-industry tables for docs/INDUSTRY_WORK_2026-11-04.md from the same definitions the migrations use:
# sql/generators/presets_v2_definition.py (records) and sql/zella_capabilities.sql (capability defaults).
# Run: python3 -I docs/generators/industry_tables.py
import json, os, re, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "sql", "generators"))
from presets_v2_definition import PRESETS as P

caps_sql = open(os.path.join(ROOT, "sql", "zella_capabilities.sql")).read()
CAPS = {m[0]: json.loads(m[1]) for m in re.findall(r"\('([a-z-]+)',\s+'(\{\"on\".*?\})'\)", caps_sql)}
SLUG_TO_PRESET = {"beauty-salon": "beauty_salon", "cleaning-services": "cleaning", "financial-services": "financial_services",
  "home-services": "home_services", "landscaping-lawn-care": "landscaping", "pest-control": "pest_control", "pet-care-veterinary": "pet_care",
  "photography-events": "photography_events", "professional-services": "professional_services", "property-management": "property_management",
  "real-estate": "real_estate", "spa-wellness": "spa_wellness"}
LABEL = {"scheduling": "Bookings", "checkins": "Check-ins", "waitlist": "Waitlist", "dispatch": "Dispatch", "classes": "Classes",
         "orders": "Orders", "money": "Money", "access_vault": "Access codes"}

def summary(key):
    v = P[key]; new, ext, priv, links, capa = [], [], [], [], []
    for t in v["types"]:
        fields = t.get("fields") or t.get("add_fields") or []
        priv += [f["label"] for f in fields if f.get("sensitive")] + [f'{t["key"]}.{s}' for s in t.get("sensitive", [])]
        links += [f'{f["label"]} → {f["target"]}' for f in fields if f.get("type") == "record"]
        if t.get("capacity"): capa.append(t.get("plural", t["key"]))
        if "add_fields" in t:
            if t["add_fields"]: ext.append(f'{t["key"]}: ' + ", ".join(f["label"] for f in t["add_fields"]))
        else: new.append(t["plural"])
    return new, ext, priv, links, capa

print("| Industry | Preset | On by default | Owner can switch on | Not offered | New record types | New fields on existing types | Private fields | Links | Capacity |")
print("|---|---|---|---|---|---|---|---|---|---|")
for slug in sorted(CAPS):
    key = SLUG_TO_PRESET.get(slug, slug)
    c = CAPS[slug]; on = c["on"]; opt = c["optional"]; off = [k for k in LABEL if k not in on and k not in opt]
    new, ext, priv, links, capa = summary(key) if key in P else ([], [], [], [], [])
    j = lambda xs: ", ".join(xs) if xs else "—"
    print(f'| {slug} | {key} | {j([LABEL[x] for x in on])} | {j([LABEL[x] for x in opt])} | {j([LABEL[x] for x in off])} | {j(new)} | {j(ext)} | {j(priv)} | {j(links)} | {j(capa)} |')
