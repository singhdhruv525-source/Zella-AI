import { automationDefaultsFor, emptyAutomations } from "./industryAutomations";
import { CATALOG, NOTIFY_OPTIONS, isPreferred, orderTypes } from "./automationCatalog";
import { EmailField, PhoneField, TimeZoneSelect, UrlField } from "./formFields";
import { checkEmail, checkUrl, countryList, validatePhone } from "./formValidation";
import { useEffect, useMemo, useRef, useState } from "react";
import "./CreateBusinessWizard.css";
import { supabase } from "./supabase";
import { Icon } from "./BusinessUI";
import { DOCUMENT_KINDS, DOCUMENT_MAX_BYTES, DOCUMENT_TYPES, LENGTH_OPTIONS, missingDetails, onboardingFor } from "./onboardingConfig";
import { humanize } from "./copy/labels";
import { friendlyError } from "./admin/adminOps";

// ---------------------------------------------------------------------------
// Server calls
// ---------------------------------------------------------------------------

export async function callOwnerFunction(action, payload = {}) {
  const fallback = "Something went wrong. Please try again.";
  const { data, error } = await supabase.functions.invoke(
    "owner-provision-business",
    { body: { action, ...payload } }
  );

  if (error) {
    let message = fallback;
    try {
      const body = await error.context?.json();
      if (body?.error) message = body.error;
    } catch {
      // Keep the fallback message.
    }
    throw new Error(message);
  }

  if (!data || data.error) throw new Error(data?.error || fallback);
  return data;
}

// ---------------------------------------------------------------------------
// Static options
// ---------------------------------------------------------------------------

// Essentials first (business, owner, hours), then what the AI and the phone need, then optional fine-tuning.
const STEPS = [
  { key: "business", label: "Business" },
  { key: "owner", label: "Owner & verification" },
  { key: "operations", label: "Hours & services" },
  { key: "team", label: "Team", optional: true },
  { key: "receptionist", label: "AI receptionist" },
  { key: "integrations", label: "Phone & integrations", optional: true },
  { key: "automations", label: "Automations" },
  { key: "crm", label: "CRM setup", optional: true },
  { key: "review", label: "Review" },
];
const STEP = Object.fromEntries(STEPS.map((s, i) => [s.key, i]));

// Where a saved draft reopens: the step after the last one that moved setup forward.
const RESUME_STEP = {
  started: STEP.business,
  business_info: STEP.owner,
  owner_setup: STEP.operations,
  industry_setup: STEP.team,
  ai_setup: STEP.integrations,
  communications_setup: STEP.automations,
  automation_setup: STEP.crm,
  testing: STEP.review,
  ready: STEP.review,
  active: STEP.review,
};

const COUNTRIES = countryList().map((c) => [c.iso, c.name]);

const TERM_ROWS = [
  { singular: "customer", plural: "customers", label: "Customers", hint: "People the business serves" },
  { singular: "staff", plural: "staff_plural", label: "Staff", hint: "People who deliver the service" },
  { singular: "service", plural: "services", label: "Services", hint: "What the business offers" },
  { singular: "appointment", plural: "appointments", label: "Appointments", hint: "Booked time slots" },
  { singular: "job", plural: "jobs", label: "Jobs", hint: "Work performed" },
  { singular: "visit", plural: "visits", label: "Visits", hint: "Each time a customer comes in or is visited" },
];

const TERM_FALLBACKS = {
  customer: "Customer", customers: "Customers", staff: "Staff member",
  staff_plural: "Staff", service: "Service", services: "Services",
  appointment: "Appointment", appointments: "Appointments", job: "Job",
  jobs: "Jobs", visit: "Visit", visits: "Visits",
};

const MODULE_DEPENDENCIES = {
  "ai-receptionist": ["calls"],
  "ai-appointments": ["calendar"],
  "ai-follow-up": ["automations"],
  "ai-sales": ["calls"],
  "ai-support": ["calls"],
};

const PERSONALITIES = [
  ["professional", "Professional", "Clear, efficient and polite"],
  ["friendly", "Friendly", "Upbeat and approachable"],
  ["warm", "Warm", "Caring and reassuring"],
  ["casual", "Casual", "Relaxed and conversational"],
  ["premium", "Premium", "Polished, concierge-style"],
];

const LANGUAGES = [
  ["en-US", "English"],
  ["es-US", "Spanish"],
  ["en-US+es-US", "English and Spanish"],
];

const CAPABILITIES = [
  ["answer_questions", "Answer customer questions"],
  ["answer_calls", "Answer phone calls"],
  ["handle_sms", "Reply to text messages"],
  ["send_emails", "Send emails"],
  ["book_appointments", "Book appointments"],
  ["reschedule_appointments", "Reschedule appointments"],
  ["cancel_appointments", "Cancel appointments"],
  ["collect_customer_info", "Collect customer details"],
  ["follow_up_leads", "Follow up with leads"],
  ["take_messages", "Take messages for the team"],
];

const ESCALATION_TRIGGERS = [
  ["customer_requests_human", "Customer asks for a person"],
  ["unknown_answer", "AI doesn't know the answer"],
  ["upset_customer", "Customer is upset"],
  ["emergency", "Emergency"],
  ["sensitive_issue", "Sensitive issue"],
  ["complex_request", "Complex request"],
  ["billing_question", "Billing question"],
];

const TRANSFER_TYPES = [
  ["owner", "Business owner"],
  ["manager", "Manager"],
  ["team_member", "Specific team member"],
  ["phone_number", "A phone number"],
];

const POLICIES = [
  ["cancellation", "Cancellation policy"],
  ["refund", "Refund policy"],
  ["payment", "Payment policy"],
  ["emergency", "Emergency policy"],
  ["appointment", "Appointment policy"],
  ["other", "Other information"],
];

const DAYS = [
  ["mon", "Monday"], ["tue", "Tuesday"], ["wed", "Wednesday"],
  ["thu", "Thursday"], ["fri", "Friday"], ["sat", "Saturday"], ["sun", "Sunday"],
];

const emptyHours = () =>
  Object.fromEntries(DAYS.map(([day]) => [day, { closed: false, open: "", close: "" }]));

const DEFAULT_AUTOMATIONS = emptyAutomations();

// Spam protection starts on, with the platform's secure defaults; the business can tune it later in its CRM.
const SPAM_DEFAULTS = {
  enabled: true, call_screening: "flag", ai_spam_handling: "end_politely", sms_monitoring: true, email_monitoring: true,
  booking_protection: true, booking_daily_limit: 3, auto_restrict: true, notify_high_risk: true,
  repeat_call_limit: 5, repeat_window_minutes: 60, sms_flood_limit: 10, email_flood_limit: 10,
};

function emptySetup() {
  return {
    business: {
      name: "", legalName: "", industryId: "", email: "", phone: "",
      website: "", addressLine1: "", addressLine2: "", city: "", state: "",
      postalCode: "", country: "US", timezone: "America/New_York",
    },
    owner: { name: "", email: "", phone: "" },
    invitation: null,
    terminology: { industry: {}, overrides: {} },
    modules: [],
    operations: {
      hours: emptyHours(), about: "", services: [], details: {},
      booking: { defaultMinutes: 30, bufferMinutes: 0, minNoticeHours: 2, maxDaysAhead: 60 },
    },
    team: [],
    documents: [],
    documentsAvailable: true,
    spam: { ...SPAM_DEFAULTS },
    spamAvailable: true,
    receptionist: {
      name: "AI Receptionist",
      greeting: "",
      language: "en-US",
      personality: "professional",
      instructions: "",
      about: "",
      serviceArea: "",
      hours: emptyHours(),
      services: [],
      faqs: [],
      policies: {},
      capabilities: ["answer_questions", "answer_calls", "collect_customer_info", "take_messages"],
      escalation: {
        triggers: ["customer_requests_human", "unknown_answer", "upset_customer", "emergency"],
        transferTo: { type: "owner", name: "", phone: "" },
      },
      bookingNotes: "",
      restrictions: "",
    },
    integrations: {
      phone: { mode: "new_number", areaCode: "", existingNumber: "", forwardWhen: "always" },
      transferNumber: "",
      calendar: "none",
      email: "none",
      leadSources: { meta: false, website: false, google: false },
    },
    automations: structuredClone(DEFAULT_AUTOMATIONS),
    industryRules: [],
    onboardingStatus: "started",
    savedSteps: {},
  };
}

// Converts the server's saved data into the wizard's form state.
function fromServer(data, industries = []) {
  const setup = emptySetup();
  const b = data.business;
  const setupData = b.setup_data || {};
  const kb = data.receptionist.knowledgeBase || {};
  const esc = data.receptionist.escalationRules || {};
  const voice = data.receptionist.voiceConfig || {};
  const integrations = setupData.integrations;

  setup.business = {
    name: b.name || "", legalName: b.legal_name || "", industryId: b.industry_id || "",
    email: b.email || "", phone: b.phone || "", website: b.website || "",
    addressLine1: b.address_line_1 || "", addressLine2: b.address_line_2 || "",
    city: b.city || "", state: b.state || "", postalCode: b.postal_code || "",
    country: b.country || "US", timezone: b.timezone || "America/New_York",
  };

  setup.invitation = data.invitation;
  setup.owner = {
    name: data.invitation?.owner_name || "",
    email: data.invitation?.email || "",
    phone: setupData.owner?.phone || "",
  };

  setup.terminology = data.terminology;
  setup.modules = data.modules;

  const hours = emptyHours();
  for (const [day] of DAYS) {
    const saved = kb.hours?.[day];
    if (saved?.closed) hours[day] = { closed: true, open: "", close: "" };
    else if (saved?.open) hours[day] = { closed: false, open: saved.open, close: saved.close };
  }

  const hasConfig = Boolean(data.receptionist.personality);

  setup.receptionist = {
    ...setup.receptionist,
    name: data.receptionist.name || "AI Receptionist",
    greeting: voice.greeting || data.terminology.industry?.voice?.greeting || "",
    language: voice.language || "en-US",
    personality: data.receptionist.personality || "professional",
    instructions: data.receptionist.tone || "",
    about: kb.about || "",
    serviceArea: kb.service_area || "",
    hours,
    services: kb.services || [],
    faqs: kb.faqs || [],
    policies: kb.policies || {},
    capabilities: hasConfig ? data.receptionist.capabilities || [] : setup.receptionist.capabilities,
    escalation: hasConfig
      ? {
          triggers: esc.triggers || [],
          transferTo: {
            type: esc.transfer_to?.type || "owner",
            name: esc.transfer_to?.name || "",
            phone: esc.transfer_to?.phone || "",
          },
        }
      : setup.receptionist.escalation,
    bookingNotes: data.receptionist.appointmentRules?.notes || "",
    restrictions: (kb.restrictions || []).join("\n"),
  };

  if (integrations) {
    setup.integrations = {
      phone: {
        mode: integrations.phone?.mode === "existing_number" ? "call_forwarding" : integrations.phone?.mode || "new_number",
        areaCode: integrations.phone?.area_code || "",
        existingNumber: integrations.phone?.forward_from || integrations.phone?.existing_number || "",
        forwardWhen: integrations.phone?.forward_when || "always",
      },
      transferNumber: integrations.transfer_number || "",
      calendar: integrations.calendar || "none",
      email: integrations.email || "none",
      leadSources: { ...setup.integrations.leadSources, ...integrations.lead_sources },
    };
  }

  // The industry decides which automations start switched on. Anything the admin
  // already saved for this business wins over those defaults.
  const industryName = industries.find((i) => i.id === setup.business.industryId)?.name;
  setup.automations = automationDefaultsFor(industryName);
  setup.automationsFromIndustry = industryName || "";
  setup.industryRules = data.industryRules || [];
  for (const row of data.automations || []) {
    if (setup.automations[row.trigger_type]) {
      setup.automations[row.trigger_type] = {
        enabled: row.status !== "disabled",
        settings: { ...setup.automations[row.trigger_type].settings, ...row.trigger_config },
      };
    }
  }

  // Hours & services: the hours table wins (the CRM and bookings read it); older drafts only have the AI's copy.
  const days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
  const opsHours = emptyHours();
  if (data.hours?.length) {
    for (const [day] of DAYS) {
      const rows = data.hours.filter((r) => days[r.weekday] === day);
      opsHours[day] = rows.length
        ? { closed: false, open: String(rows[0].opens).slice(0, 5), close: String(rows[rows.length - 1].closes).slice(0, 5) }
        : { closed: true, open: "", close: "" };
    }
  } else {
    Object.assign(opsHours, hours);
  }
  const saved = data.operations || {};
  const industrySlug = industries.find((i) => i.id === setup.business.industryId)?.slug;
  const cfg = onboardingFor(industrySlug);
  setup.operations = {
    hours: opsHours,
    about: b.description || kb.about || "",
    services: kb.services || [],
    details: Object.fromEntries((saved.details || []).map((d) => [d.key, d.value])),
    booking: {
      defaultMinutes: saved.booking?.default_minutes ?? cfg.defaultLength,
      bufferMinutes: saved.booking?.buffer_minutes ?? 0,
      minNoticeHours: saved.booking?.min_notice_hours ?? 2,
      maxDaysAhead: saved.booking?.max_days_ahead ?? 60,
    },
  };
  if (!saved.details?.length && kb.service_area && cfg.details.some((d) => d.key === "service_area")) setup.operations.details.service_area = kb.service_area;
  setup.team = (data.team || []).map((m) => ({ id: m.id, name: m.name || "", title: m.title || "", phone: m.phone || "", email: m.email || "" }));
  setup.documents = data.documents || [];
  setup.documentsAvailable = data.documentsAvailable !== false;
  if (!hasConfig) setup.receptionist.capabilities = cfg.capabilities;
  setup.spamAvailable = data.spamAvailable !== false;
  setup.spam = data.spam
    ? Object.fromEntries(Object.keys(SPAM_DEFAULTS).map((k) => [k, data.spam[k] ?? SPAM_DEFAULTS[k]]))
    : { ...SPAM_DEFAULTS, booking_daily_limit: cfg.spamBookingLimit ?? SPAM_DEFAULTS.booking_daily_limit };

  setup.onboardingStatus = b.onboarding_status;
  return setup;
}

function termFor(terminology, key) {
  return (
    terminology.overrides?.[key] ||
    terminology.industry?.[key] ||
    TERM_FALLBACKS[key] ||
    key
  );
}

// ---------------------------------------------------------------------------
// Small building blocks
// ---------------------------------------------------------------------------

function Field({ label, required, hint, children, full, bare }) {
  const Tag = bare ? "div" : "label";
  return (
    <Tag className={`owner-field ${full ? "wiz-field-full" : ""}`}>
      <span>{label}{required ? " *" : ""}</span>
      {children}
      {hint && <small className="wiz-hint">{hint}</small>}
    </Tag>
  );
}

function Section({ title, description, children, aside }) {
  return (
    <section className="wiz-section">
      <div className="wiz-section-head">
        <div>
          <h3>{title}</h3>
          {description && <p>{description}</p>}
        </div>
        {aside}
      </div>
      {children}
    </section>
  );
}

function Toggle({ checked, onChange, label, disabled }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      className={`wiz-toggle ${checked ? "on" : ""}`}
      onClick={() => !disabled && onChange(!checked)}
      disabled={disabled}
    >
      <span />
    </button>
  );
}

function CheckGrid({ options, values, onChange }) {
  return (
    <div className="wiz-check-grid">
      {options.map(([value, label]) => (
        <label key={value} className={`wiz-check ${values.includes(value) ? "checked" : ""}`}>
          <input
            type="checkbox"
            checked={values.includes(value)}
            onChange={(event) =>
              onChange(
                event.target.checked
                  ? [...values, value]
                  : values.filter((item) => item !== value)
              )
            }
          />
          <span>{label}</span>
        </label>
      ))}
    </div>
  );
}

function Badge({ tone = "neutral", children }) {
  // Sentence case: "Preferred for this business", "Sent". Plain status words from the server start lower case.
  const text = typeof children === "string" ? humanize(children) : children;
  return <span className={`wiz-badge wiz-badge-${tone}`}>{text}</span>;
}

function AutoSelect({ item, setting, options, onSet, numeric = true }) {
  return (
    <select
      value={item.settings[setting]}
      disabled={!item.enabled}
      onChange={(e) => onSet(setting, numeric ? Number(e.target.value) : e.target.value)}
    >
      {options.map(([v, label]) => <option key={v} value={v}>{label}</option>)}
    </select>
  );
}

function ConnectionRow({ name, detail, children }) {
  return (
    <div className="wiz-connection">
      <div>
        <strong>{name}</strong>
        <span>{detail}</span>
      </div>
      <div className="wiz-connection-side">
        {children}
        <Badge>Not connected</Badge>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

function BusinessStep({ value, onChange, industries, isExisting, locked, showErrors }) {
  const set = (key) => (event) => onChange({ ...value, [key]: event.target.value });

  return (
    <>
      <Section title="Business details" description="The basics Zella uses across the CRM and the AI receptionist.">
        <div className="owner-form-grid">
          <Field label="Business name" required>
            <input value={value.name} onChange={set("name")} placeholder="e.g. Sunshine Dental Clinic" />
          </Field>
          <Field label="Legal name" hint="If different from the business name">
            <input value={value.legalName} onChange={set("legalName")} />
          </Field>
          <Field
            label="Industry"
            required
            hint={isExisting && !locked ? "Changing the industry resets terminology and modules." : locked ? "Locked after setup is finished." : undefined}
          >
            <select value={value.industryId} onChange={set("industryId")} disabled={locked}>
              <option value="">{industries.length ? "Select industry" : "No industries available"}</option>
              {industries.map((industry) => (
                <option key={industry.id} value={industry.id}>{industry.name}</option>
              ))}
            </select>
          </Field>
          <Field label="Timezone" required bare>
            <TimeZoneSelect value={value.timezone} onChange={(timezone) => onChange({ ...value, timezone })} />
          </Field>
          <Field label="Business email" bare>
            <EmailField value={value.email} onChange={(email) => onChange({ ...value, email })} placeholder="hello@business.com" showErrors={showErrors} />
          </Field>
          <Field label="Business phone" hint="The number customers know today" bare>
            <PhoneField value={value.phone} onChange={(phone) => onChange({ ...value, phone })} showErrors={showErrors} label="Business phone" />
          </Field>
          <Field label="Website" full bare>
            <UrlField value={value.website} onChange={(website) => onChange({ ...value, website })} showErrors={showErrors} />
          </Field>
        </div>
      </Section>

      <Section title="Address">
        <div className="owner-form-grid">
          <Field label="Street address" full>
            <input value={value.addressLine1} onChange={set("addressLine1")} />
          </Field>
          <Field label="Address line 2" full>
            <input value={value.addressLine2} onChange={set("addressLine2")} placeholder="Suite, unit, floor" />
          </Field>
          <Field label="City"><input value={value.city} onChange={set("city")} /></Field>
          <Field label="State"><input value={value.state} onChange={set("state")} /></Field>
          <Field label="ZIP / postal code"><input value={value.postalCode} onChange={set("postalCode")} /></Field>
          <Field label="Country">
            <select value={value.country} onChange={set("country")}>
              {COUNTRIES.map(([code, label]) => <option key={code} value={code}>{label}</option>)}
            </select>
          </Field>
        </div>
      </Section>
    </>
  );
}

function OwnerStep({ value, onChange, invitation, showErrors }) {
  const set = (key) => (event) => onChange({ ...value, [key]: event.target.value });
  const sent = invitation && ["sent", "accepted"].includes(invitation.status);

  return (
    <Section
      title="Business owner"
      description="The owner gets their own login to this business's workspace."
      aside={invitation && <Badge tone={invitation.status === "failed" ? "danger" : sent ? "success" : "neutral"}>Invitation: {invitation.status}</Badge>}
    >
      <div className="owner-form-grid">
        <Field label="Owner full name" required>
          <input value={value.name} onChange={set("name")} placeholder="Full name" />
        </Field>
        <Field label="Owner email / login" required bare hint={sent ? "Already invited, so the email can't be changed here." : undefined}>
          <EmailField value={value.email} onChange={(email) => onChange({ ...value, email })} placeholder="owner@business.com" disabled={sent} required showErrors={showErrors} />
        </Field>
        <Field label="Owner phone" bare>
          <PhoneField value={value.phone} onChange={(phone) => onChange({ ...value, phone })} showErrors={showErrors} label="Owner phone" />
        </Field>
      </div>
      <div className="wiz-note">
        The invitation email is sent when you finish setup on the Review step, not now.
        {invitation?.last_error && <><br />Last error: {invitation.last_error}</>}
      </div>
    </Section>
  );
}

function TerminologyStep({ value, onChange }) {
  const setOverride = (key, text) => {
    const overrides = { ...value.overrides, [key]: text };
    if (!text.trim()) delete overrides[key];
    onChange({ ...value, overrides });
  };

  const changed = Object.keys(value.overrides || {}).length;

  return (
    <div className="wiz-two-col">
      <Section
        title="CRM terminology"
        description="Defaults come from the industry. Change any word to match how this business talks."
        aside={changed > 0 && (
          <button type="button" className="owner-secondary-button" onClick={() => onChange({ ...value, overrides: {} })}>
            Reset to industry defaults
          </button>
        )}
      >
        <div className="wiz-term-table">
          <div className="wiz-term-head">
            <span>Term</span><span>Singular</span><span>Plural</span>
          </div>
          {TERM_ROWS.map((row) => (
            <div className="wiz-term-row" key={row.singular}>
              <div>
                <strong>{row.label}</strong>
                <small>{row.hint}</small>
              </div>
              {[row.singular, row.plural].map((key) => (
                <input
                  key={key}
                  aria-label={`${row.label} ${key === row.singular ? "singular" : "plural"}`}
                  value={value.overrides?.[key] || ""}
                  placeholder={value.industry?.[key] || TERM_FALLBACKS[key]}
                  onChange={(event) => setOverride(key, event.target.value)}
                />
              ))}
            </div>
          ))}
        </div>
        <p className="wiz-hint">Leave a box empty to use the industry default shown in grey.</p>
      </Section>

      <aside className="wiz-preview">
        <div className="wiz-preview-label">Workspace preview</div>
        <div className="wiz-preview-nav">
          {["Today", termFor(value, "customers"), termFor(value, "appointments"), termFor(value, "jobs"), "Calls", termFor(value, "staff_plural")].map((item, index) => (
            <div key={`${item}-${index}`} className={index === 1 ? "active" : ""}>{item}</div>
          ))}
        </div>
        <div className="wiz-preview-card">
          <strong>New {termFor(value, "customer").toLowerCase()}</strong>
          <span>Book {termFor(value, "appointment").toLowerCase()} with a {termFor(value, "staff").toLowerCase()}</span>
        </div>
      </aside>
    </div>
  );
}

function ModulesStep({ modules, onChange }) {
  const bySlug = useMemo(() => new Map(modules.map((m) => [m.slug, m])), [modules]);

  const requiredBy = (module) =>
    modules.filter(
      (other) => other.enabled && (MODULE_DEPENDENCIES[other.slug] || []).includes(module.slug)
    );

  const toggle = (module, enabled) => {
    const next = new Map(modules.map((m) => [m.slug, { ...m }]));
    next.get(module.slug).enabled = enabled;

    if (enabled) {
      const stack = [module.slug];
      while (stack.length) {
        for (const dependency of MODULE_DEPENDENCIES[stack.pop()] || []) {
          const dep = next.get(dependency);
          if (dep && !dep.enabled) {
            dep.enabled = true;
            stack.push(dependency);
          }
        }
      }
    }
    onChange(modules.map((m) => next.get(m.slug)));
  };

  if (!modules.length) {
    return (
      <Section title="Modules">
        <div className="owner-empty-state">
          <strong>No modules are configured for this industry yet</strong>
          <p>Add modules to the industry in Industry Configuration, then return here.</p>
        </div>
      </Section>
    );
  }

  return (
    <Section
      title="Modules"
      description="Choose which parts of the CRM this business gets. Modules a selected feature needs are turned on automatically."
      aside={<Badge>{modules.filter((m) => m.enabled).length} of {modules.length} on</Badge>}
    >
      <div className="wiz-module-grid">
        {modules.map((module) => {
          const dependents = requiredBy(module);
          const needs = (MODULE_DEPENDENCIES[module.slug] || [])
            .map((slug) => bySlug.get(slug)?.name)
            .filter(Boolean);

          return (
            <div key={module.id} className={`wiz-module ${module.enabled ? "on" : ""}`}>
              <div className="wiz-module-top">
                <strong>{module.name}</strong>
                <Toggle
                  checked={module.enabled}
                  label={module.name}
                  disabled={module.enabled && dependents.length > 0}
                  onChange={(enabled) => toggle(module, enabled)}
                />
              </div>
              {module.description && <p>{module.description}</p>}
              {needs.length > 0 && <small>Needs {needs.join(", ")}</small>}
              {module.enabled && dependents.length > 0 && (
                <small>Required by {dependents.map((d) => d.name).join(", ")}</small>
              )}
            </div>
          );
        })}
      </div>
    </Section>
  );
}

function ListEditor({ items, onChange, fields, addLabel, emptyText }) {
  const update = (index, key, text) =>
    onChange(items.map((item, i) => (i === index ? { ...item, [key]: text } : item)));

  return (
    <div className="wiz-list">
      {items.length === 0 && <div className="wiz-empty">{emptyText}</div>}
      {items.map((item, index) => (
        <div className="wiz-list-item" key={index}>
          <div className="owner-form-grid">
            {fields.map((field) => (
              <Field key={field.key} label={field.label} required={field.required} full={field.full}>
                {field.multiline ? (
                  <textarea value={item[field.key] || ""} placeholder={field.placeholder} onChange={(e) => update(index, field.key, e.target.value)} />
                ) : (
                  <input value={item[field.key] || ""} placeholder={field.placeholder} onChange={(e) => update(index, field.key, e.target.value)} />
                )}
              </Field>
            ))}
          </div>
          <button type="button" className="wiz-link-danger" onClick={() => onChange(items.filter((_, i) => i !== index))}>
            Remove
          </button>
        </div>
      ))}
      <button
        type="button"
        className="owner-secondary-button"
        onClick={() => onChange([...items, Object.fromEntries(fields.map((f) => [f.key, ""]))])}
      >
        ＋ {addLabel}
      </button>
    </div>
  );
}

function ReceptionistStep({ value, onChange, terminology, showErrors, faqPrompts = [] }) {
  const set = (key) => (event) => onChange({ ...value, [key]: event.target.value });
  const asked = new Set(value.faqs.map((f) => f.question.trim().toLowerCase()));
  const prompts = faqPrompts.filter((q) => !asked.has(q.toLowerCase()));

  return (
    <>
      <Section title="Identity & voice" description="How the receptionist introduces itself and speaks.">
        <div className="owner-form-grid">
          <Field label="Receptionist name"><input value={value.name} onChange={set("name")} /></Field>
          <Field label="Language">
            <select value={value.language} onChange={set("language")}>
              {LANGUAGES.map(([code, label]) => <option key={code} value={code}>{label}</option>)}
            </select>
          </Field>
          <Field label="Greeting" full hint="The first thing callers hear.">
            <textarea value={value.greeting} onChange={set("greeting")} />
          </Field>
        </div>
        <div className="wiz-choice-row">
          {PERSONALITIES.map(([key, label, description]) => (
            <button
              type="button"
              key={key}
              className={`wiz-choice ${value.personality === key ? "selected" : ""}`}
              onClick={() => onChange({ ...value, personality: key })}
            >
              <strong>{label}</strong>
              <span>{description}</span>
            </button>
          ))}
        </div>
        <Field label="Extra communication instructions" full>
          <textarea value={value.instructions} onChange={set("instructions")} placeholder="e.g. Always confirm the caller's name before ending the call." />
        </Field>
      </Section>

      <Section title="FAQs" description="Questions customers often ask, with the business's real answers.">
        {prompts.length > 0 && (
          <div className="wiz-chip-row wiz-prompts">
            <span className="wiz-hint">Often asked:</span>
            {prompts.map((q) => (
              <button key={q} type="button" className="wiz-chip" onClick={() => onChange({ ...value, faqs: [...value.faqs, { question: q, answer: "" }] })}>＋ {q}</button>
            ))}
          </div>
        )}
        <ListEditor
          items={value.faqs}
          onChange={(items) => onChange({ ...value, faqs: items })}
          addLabel="Add FAQ"
          emptyText="No FAQs added yet."
          fields={[
            { key: "question", label: "Question", required: true, full: true },
            { key: "answer", label: "Answer", required: true, full: true, multiline: true },
          ]}
        />
      </Section>

      <Section title="Policies">
        <div className="owner-form-grid">
          {POLICIES.map(([key, label]) => (
            <Field key={key} label={label} full>
              <textarea
                value={value.policies[key] || ""}
                onChange={(e) => onChange({ ...value, policies: { ...value.policies, [key]: e.target.value } })}
              />
            </Field>
          ))}
        </div>
      </Section>

      <Section title="What the AI can do">
        <CheckGrid options={CAPABILITIES} values={value.capabilities} onChange={(capabilities) => onChange({ ...value, capabilities })} />
        <Field label={`${termFor(terminology, "appointment")} booking notes`} full>
          <textarea value={value.bookingNotes} onChange={set("bookingNotes")} placeholder="e.g. New patients need a 60-minute slot." />
        </Field>
      </Section>

      <Section title="When to hand over to a person">
        <CheckGrid
          options={ESCALATION_TRIGGERS}
          values={value.escalation.triggers}
          onChange={(triggers) => onChange({ ...value, escalation: { ...value.escalation, triggers } })}
        />
        <div className="owner-form-grid wiz-gap-top">
          <Field label="Transfer to">
            <select
              value={value.escalation.transferTo.type}
              onChange={(e) => onChange({ ...value, escalation: { ...value.escalation, transferTo: { ...value.escalation.transferTo, type: e.target.value } } })}
            >
              {TRANSFER_TYPES.map(([key, label]) => <option key={key} value={key}>{label}</option>)}
            </select>
          </Field>
          <Field label="Name">
            <input
              value={value.escalation.transferTo.name}
              onChange={(e) => onChange({ ...value, escalation: { ...value.escalation, transferTo: { ...value.escalation.transferTo, name: e.target.value } } })}
            />
          </Field>
          <Field label="Transfer phone number" full bare>
            <PhoneField
              value={value.escalation.transferTo.phone}
              showErrors={showErrors}
              label="Transfer phone number"
              onChange={(phone) => onChange({ ...value, escalation: { ...value.escalation, transferTo: { ...value.escalation.transferTo, phone } } })}
            />
          </Field>
        </div>
      </Section>

      <Section title="Things the AI must never say or do" description="One per line.">
        <textarea
          className="wiz-textarea"
          value={value.restrictions}
          onChange={set("restrictions")}
          placeholder={"e.g. Never give medical advice\nNever promise a same-day appointment"}
        />
      </Section>
    </>
  );
}

function IntegrationsStep({ value, onChange, showErrors }) {
  const setPhone = (patch) => onChange({ ...value, phone: { ...value.phone, ...patch } });
  const setLead = (key, on) => onChange({ ...value, leadSources: { ...value.leadSources, [key]: on } });


  return (
    <>
      <div className="wiz-note">
        This step records what the business needs. Each service shows <strong>Not connected</strong> until
        it is actually connected and verified after setup.
      </div>

      <Section title="Phone setup (Telnyx)" description="How callers will reach the AI receptionist.">
        <div className="wiz-choice-row">
          {[
            ["new_number", "Get a new Zella number", "Zella gives the business a new local number to publish"],
            ["call_forwarding", "Call forwarding", "The business keeps its number and forwards calls to Zella"],
          ].map(([mode, label, description]) => (
            <button
              type="button"
              key={mode}
              className={`wiz-choice ${value.phone.mode === mode ? "selected" : ""}`}
              onClick={() => setPhone({ mode })}
            >
              <strong>{label}</strong>
              <span>{description}</span>
            </button>
          ))}
        </div>
        <div className="owner-form-grid">
          {value.phone.mode === "call_forwarding" && (
            <>
              <Field label="Business number to forward" required bare hint="The number customers already call">
                <PhoneField value={value.phone.existingNumber} onChange={(existingNumber) => setPhone({ existingNumber })} required showErrors={showErrors} label="Business number to forward" />
              </Field>
              <Field label="Forward calls" required>
                <select value={value.phone.forwardWhen} onChange={(e) => setPhone({ forwardWhen: e.target.value })}>
                  <option value="always">All calls</option>
                  <option value="no_answer">Only when nobody answers</option>
                  <option value="busy_or_no_answer">When busy or nobody answers</option>
                  <option value="after_hours">Only after business hours</option>
                </select>
              </Field>
            </>
          )}
          <Field
            label={value.phone.mode === "new_number" ? "Preferred area code" : "Zella number area code"}
            hint={value.phone.mode === "new_number" ? "3 digits, optional" : "Calls are forwarded to a Zella number; 3 digits, optional"}
          >
            <input inputMode="numeric" maxLength={3} value={value.phone.areaCode} onChange={(e) => setPhone({ areaCode: e.target.value.replace(/\D/g, "") })} />
          </Field>
          <Field label="Call transfer number" hint="Where the AI sends calls it shouldn't handle" bare>
            <PhoneField value={value.transferNumber} onChange={(transferNumber) => onChange({ ...value, transferNumber })} showErrors={showErrors} label="Call transfer number" />
          </Field>
        </div>
      </Section>

      <Section title="Voice agent (Vapi)">
        <div className="wiz-connection">
          <div>
            <strong>AI receptionist voice agent</strong>
            <span>Created from this business's AI receptionist settings when it goes live.</span>
          </div>
          <Badge>Not created</Badge>
        </div>
      </Section>

      <Section title="Calendar & email">
        <div className="owner-form-grid">
          <Field label="Calendar for bookings">
            <select value={value.calendar} onChange={(e) => onChange({ ...value, calendar: e.target.value })}>
              <option value="none">None yet</option>
              <option value="google">Google Calendar</option>
              <option value="outlook">Outlook Calendar</option>
            </select>
          </Field>
          <Field label="Email">
            <select value={value.email} onChange={(e) => onChange({ ...value, email: e.target.value })}>
              <option value="none">None yet</option>
              <option value="gmail">Gmail</option>
              <option value="outlook">Outlook</option>
            </select>
          </Field>
        </div>
      </Section>

      <Section title="Lead sources" description="New leads from these sources go into the CRM and can trigger an automatic AI callback.">
        <ConnectionRow name="Meta lead ads" detail="Facebook and Instagram lead forms">
          <Toggle checked={value.leadSources.meta} label="Meta lead ads" onChange={(on) => setLead("meta", on)} />
        </ConnectionRow>
        <ConnectionRow name="Website form" detail="Enquiries from the business's website">
          <Toggle checked={value.leadSources.website} label="Website form" onChange={(on) => setLead("website", on)} />
        </ConnectionRow>
        <ConnectionRow name="Google" detail="Google Ads lead forms and Business Profile">
          <Toggle checked={value.leadSources.google} label="Google" onChange={(on) => setLead("google", on)} />
        </ConnectionRow>
      </Section>
    </>
  );
}

const SWITCHES = CATALOG;

// Step 2: switch each automation on or off. The choices start from what's usual for the industry.
function AutomationSwitchesStep({ value, onChange, terminology, industryName, rules = [], onRules }) {
  const appt = termFor(terminology, "appointment").toLowerCase();
  const setAll = (enabled) => {
    onChange(Object.fromEntries(Object.entries(value).map(([type, item]) => [type, { ...item, enabled }])));
    onRules?.(rules.map((r) => ({ ...r, enabled })));
  };
  const setRule = (name, patch) => onRules?.(rules.map((r) => (r.name === name ? { ...r, ...patch } : r)));
  const madeFor = rules.filter((r) => r.preferred);
  const general = rules.filter((r) => !r.preferred);
  const setOne = (type, enabled) => onChange({ ...value, [type]: { ...value[type], enabled } });
  const setNotify = (type, notify_via) => onChange({ ...value, [type]: { ...value[type], settings: { ...value[type].settings, notify_via } } });
  const onCount = SWITCHES.filter(([type]) => value[type]?.enabled).length + rules.filter((r) => r.enabled).length;
  const total = SWITCHES.length + rules.length;
  const ruleCard = (r) => (
    <div key={r.name} className={`wiz-automation ${r.enabled ? "on" : ""}`}>
      <div className="wiz-module-top">
        <div>
          <strong>{r.name}{r.preferred && <> <Badge tone="success">Preferred for this business</Badge></>}</strong>
          <p>{r.description}</p>
        </div>
        <Toggle checked={Boolean(r.enabled)} label={r.name} onChange={(enabled) => setRule(r.name, { enabled })} />
      </div>
      {r.enabled && (
        <label className="wiz-notify">
          <span>Tell the owner by</span>
          <select value={r.notifyVia || "both"} onChange={(e) => setRule(r.name, { notifyVia: e.target.value })}>
            {NOTIFY_OPTIONS.map(([v, label]) => <option key={v} value={v}>{label}</option>)}
          </select>
        </label>
      )}
    </div>
  );
  return (
    <>
      <Section
        title="Automations"
        description={industryName
          ? `Switched on for you, the usual ones for ${industryName}. Turn any on or off. You can fine-tune each one later.`
          : "Turn each automation on or off. You can fine-tune each one later."}
        aside={
          <div className="wiz-switch-all">
            <button type="button" className="wiz-link" onClick={() => setAll(true)}>Turn all on</button>
            <button type="button" className="wiz-link" onClick={() => setAll(false)}>Turn all off</button>
          </div>
        }
      >
        <p className="wiz-hint">{onCount} of {total} on. They start running when the business goes live.</p>
        <div className="wiz-automation-list">
          {orderTypes(SWITCHES.map(([type]) => type), industryName).map((type) => {
            const [, title, text] = SWITCHES.find(([k]) => k === type);
            const preferred = Boolean(industryName) && isPreferred(type, industryName);
            const name = title(termFor(terminology, "appointment"));
            return (
              <div key={type} className={`wiz-automation ${value[type]?.enabled ? "on" : ""}`}>
                <div className="wiz-module-top">
                  <div>
                    <strong>{name}{preferred && <> <Badge tone="success">Preferred for this business</Badge></>}</strong>
                    <p>{text(appt)}</p>
                  </div>
                  <Toggle checked={Boolean(value[type]?.enabled)} label={name} onChange={(enabled) => setOne(type, enabled)} />
                </div>
                {value[type]?.enabled && (
                  <label className="wiz-notify">
                    <span>Tell the owner by</span>
                    <select value={value[type]?.settings?.notify_via || "both"} onChange={(e) => setNotify(type, e.target.value)}>
                      {NOTIFY_OPTIONS.map(([v, label]) => <option key={v} value={v}>{label}</option>)}
                    </select>
                  </label>
                )}
              </div>
            );
          })}
        </div>
        {madeFor.length > 0 && (
          <>
            <h4 className="wiz-group-title">Made for {industryName || "this business"}</h4>
            <p className="wiz-hint">These follow your {industryName ? industryName.toLowerCase() : "industry"} records and customers, such as a status change or a service coming due.</p>
            <div className="wiz-automation-list">{madeFor.map(ruleCard)}</div>
          </>
        )}
        {general.length > 0 && (
          <>
            <h4 className="wiz-group-title">Also available</h4>
            <div className="wiz-automation-list">{general.map(ruleCard)}</div>
          </>
        )}
      </Section>
    </>
  );
}

function AutomationsStep({ value, onChange, terminology, industryName }) {
  const appt = termFor(terminology, "appointment").toLowerCase();
  const appts = termFor(terminology, "appointments").toLowerCase();

  const set = (type, patch) =>
    onChange({ ...value, [type]: { ...value[type], ...patch } });
  const setSetting = (type, key, v) =>
    set(type, { settings: { ...value[type].settings, [key]: v } });


  const reminderHours = value.appointment_reminder.settings.hours_before || [];

  const cards = [
    {
      type: "appointment_reminder",
      title: `${termFor(terminology, "appointment")} reminders`,
      description: `Remind customers before their ${appt}.`,
      body: (
        <>
          <div className="wiz-chip-row">
            {[[48, "2 days"], [24, "1 day"], [4, "4 hours"], [2, "2 hours"], [1, "1 hour"], [0.5, "30 min"], [0.25, "15 min"]].map(([h, label]) => (
              <label key={h} className={`wiz-chip ${reminderHours.includes(h) ? "on" : ""}`}>
                <input
                  type="checkbox"
                  disabled={!value.appointment_reminder.enabled}
                  checked={reminderHours.includes(h)}
                  onChange={(e) =>
                    setSetting("appointment_reminder", "hours_before",
                      e.target.checked ? [...reminderHours, h] : reminderHours.filter((x) => x !== h))
                  }
                />
                {label} before
              </label>
            ))}
          </div>
          <label className="wiz-inline">Send by <AutoSelect item={value.appointment_reminder} onSet={(k, v) => setSetting("appointment_reminder", k, v)} setting="channel" numeric={false} options={[["sms", "Text"], ["call", "AI call"], ["sms_and_call", "Text and AI call"]]} /></label>
        </>
      ),
    },
    {
      type: "appointment_confirmation",
      title: "Confirmation & check-in",
      description: `Ask customers to confirm their ${appt}.`,
      body: (
        <label className="wiz-inline">
          Ask <AutoSelect item={value.appointment_confirmation} onSet={(k, v) => setSetting("appointment_confirmation", k, v)} setting="hours_before" options={[[24, "1 day"], [48, "2 days"], [72, "3 days"]]} /> before by
          <AutoSelect item={value.appointment_confirmation} onSet={(k, v) => setSetting("appointment_confirmation", k, v)} setting="channel" numeric={false} options={[["sms", "text"], ["call", "AI call"]]} />
        </label>
      ),
    },
    {
      type: "no_show_follow_up",
      title: "No-show follow-up",
      description: `Reach out when someone misses their ${appt} and offer to rebook.`,
      body: (
        <label className="wiz-inline">
          After <AutoSelect item={value.no_show_follow_up} onSet={(k, v) => setSetting("no_show_follow_up", k, v)} setting="minutes_after" options={[[10, "10 min"], [15, "15 min"], [30, "30 min"], [60, "1 hour"]]} /> by
          <AutoSelect item={value.no_show_follow_up} onSet={(k, v) => setSetting("no_show_follow_up", k, v)} setting="channel" numeric={false} options={[["call", "AI call"], ["sms", "text"]]} />
        </label>
      ),
    },
    {
      type: "missed_call_follow_up",
      title: "Missed-call recovery",
      description: "Call back anyone whose call was missed.",
      body: (
        <>
          <label className="wiz-inline">
            Call back <AutoSelect item={value.missed_call_follow_up} onSet={(k, v) => setSetting("missed_call_follow_up", k, v)} setting="minutes_after" options={[[0, "immediately"], [5, "after 5 min"], [15, "after 15 min"], [30, "after 30 min"]]} />, up to
            <AutoSelect item={value.missed_call_follow_up} onSet={(k, v) => setSetting("missed_call_follow_up", k, v)} setting="max_attempts" options={[[1, "1 try"], [2, "2 tries"], [3, "3 tries"]]} />
          </label>
          <label className="wiz-inline-check">
            <input type="checkbox" disabled={!value.missed_call_follow_up.enabled} checked={value.missed_call_follow_up.settings.fallback_sms} onChange={(e) => setSetting("missed_call_follow_up", "fallback_sms", e.target.checked)} />
            Send a text if they don't answer
          </label>
        </>
      ),
    },
    {
      type: "new_lead_callback",
      title: "New lead callback",
      description: "Call new leads from Meta, the website and other sources.",
      body: (
        <>
          <label className="wiz-inline">
            Call <AutoSelect item={value.new_lead_callback} onSet={(k, v) => setSetting("new_lead_callback", k, v)} setting="minutes_after" options={[[0, "immediately"], [5, "after 5 min"], [15, "after 15 min"], [60, "after 1 hour"]]} />, up to
            <AutoSelect item={value.new_lead_callback} onSet={(k, v) => setSetting("new_lead_callback", k, v)} setting="max_attempts" options={[[1, "1 try"], [2, "2 tries"], [3, "3 tries"]]} />, retry after
            <AutoSelect item={value.new_lead_callback} onSet={(k, v) => setSetting("new_lead_callback", k, v)} setting="retry_after_hours" options={[[1, "1 hour"], [4, "4 hours"], [24, "1 day"]]} />
          </label>
          <label className="wiz-inline-check">
            <input type="checkbox" disabled={!value.new_lead_callback.enabled} checked={value.new_lead_callback.settings.fallback_sms} onChange={(e) => setSetting("new_lead_callback", "fallback_sms", e.target.checked)} />
            Send a text if they don't answer
          </label>
          <label className="wiz-inline">
            Contact within <AutoSelect item={value.new_lead_callback} onSet={(k, v) => setSetting("new_lead_callback", k, v)} setting="contact_within_minutes" options={[[5, "5 min"], [15, "15 min"], [30, "30 min"], [60, "1 hour"]]} />, tell the team after <AutoSelect item={value.new_lead_callback} onSet={(k, v) => setSetting("new_lead_callback", k, v)} setting="escalate_after_minutes" options={[[30, "30 min"], [60, "1 hour"], [120, "2 hours"], [240, "4 hours"]]} />
          </label>
        </>
      ),
    },
    {
      type: "post_appointment_follow_up",
      title: `After-${appt} follow-up`,
      description: "Thank customers and ask for feedback.",
      body: (
        <label className="wiz-inline">
          <AutoSelect item={value.post_appointment_follow_up} onSet={(k, v) => setSetting("post_appointment_follow_up", k, v)} setting="hours_after" options={[[2, "2 hours"], [24, "1 day"], [72, "3 days"]]} /> after, by
          <AutoSelect item={value.post_appointment_follow_up} onSet={(k, v) => setSetting("post_appointment_follow_up", k, v)} setting="channel" numeric={false} options={[["sms", "text"], ["email", "email"]]} />
        </label>
      ),
    },
    {
      type: "quote_follow_up",
      title: "Quote follow-up",
      description: "Check in with people who were sent a quote and haven't replied.",
      body: (
        <label className="wiz-inline">
          After <AutoSelect item={value.quote_follow_up} onSet={(k, v) => setSetting("quote_follow_up", k, v)} setting="hours_after" options={[[24, "1 day"], [48, "2 days"], [72, "3 days"]]} />, up to <AutoSelect item={value.quote_follow_up} onSet={(k, v) => setSetting("quote_follow_up", k, v)} setting="max_attempts" options={[[1, "1 try"], [2, "2 tries"], [3, "3 tries"]]} />, by <AutoSelect item={value.quote_follow_up} onSet={(k, v) => setSetting("quote_follow_up", k, v)} setting="channel" numeric={false} options={[["sms", "text"], ["email", "email"]]} />
        </label>
      ),
    },
    {
      type: "lead_reactivation",
      title: "Win back quiet customers",
      description: "Reach out to people you haven't heard from in a while.",
      body: (
        <label className="wiz-inline">
          After <AutoSelect item={value.lead_reactivation} onSet={(k, v) => setSetting("lead_reactivation", k, v)} setting="days_inactive" options={[[14, "2 weeks"], [30, "30 days"], [60, "60 days"], [90, "90 days"]]} /> without contact, by <AutoSelect item={value.lead_reactivation} onSet={(k, v) => setSetting("lead_reactivation", k, v)} setting="channel" numeric={false} options={[["sms", "text"], ["email", "email"]]} />
        </label>
      ),
    },
    {
      type: "waitlist_offer",
      title: "Waitlist offers",
      description: `When ${/^[aeiou]/i.test(appt) ? "an" : "a"} ${appt} opens up, offer it to people waiting.`,
      body: (
        <label className="wiz-inline">
          Offer to <AutoSelect item={value.waitlist_offer} onSet={(k, v) => setSetting("waitlist_offer", k, v)} setting="offers" options={[[1, "1"], [3, "3"], [5, "5"]]} /> people, each gets <AutoSelect item={value.waitlist_offer} onSet={(k, v) => setSetting("waitlist_offer", k, v)} setting="offer_minutes" options={[[15, "15 min"], [30, "30 min"], [60, "1 hour"]]} />, by <AutoSelect item={value.waitlist_offer} onSet={(k, v) => setSetting("waitlist_offer", k, v)} setting="channel" numeric={false} options={[["sms", "text"], ["email", "email"]]} />
        </label>
      ),
    },
    {
      type: "staff_unavailable",
      title: "Team member unavailable",
      description: `Tell customers and offer another time when their ${appt} can't go ahead.`,
      body: (
        <label className="wiz-inline">
          Notify by <AutoSelect item={value.staff_unavailable} onSet={(k, v) => setSetting("staff_unavailable", k, v)} setting="channel" numeric={false} options={[["sms", "text"], ["email", "email"]]} />
        </label>
      ),
    },
  ];

  return (
    <>
      {industryName && (
        <div className="wiz-note">
          These starting choices are the usual ones for <strong>{industryName}</strong>. Change anything you like.
        </div>
      )}
      <div className="wiz-note">
        Automations are saved as <strong>paused</strong> and start running through n8n only when this business
        goes live. Wording uses this business's terms ({appts}).
      </div>
      <div className="wiz-automation-list">
        {cards.map((card) => (
          <div key={card.type} className={`wiz-automation ${value[card.type].enabled ? "on" : ""}`}>
            <div className="wiz-module-top">
              <div>
                <strong>{card.title}</strong>
                <p>{card.description}</p>
              </div>
              <Toggle checked={value[card.type].enabled} label={card.title} onChange={(enabled) => set(card.type, { enabled })} />
            </div>
            <div className="wiz-automation-body">{card.body}</div>
          </div>
        ))}
      </div>
    </>
  );
}


// ---------------------------------------------------------------------------
// Owner & verification: documents
// ---------------------------------------------------------------------------

const DOC_STATUS = {
  pending_review: ["neutral", "Waiting for review"],
  verified: ["success", "Verified"],
  rejected: ["danger", "Rejected"],
};

function DocumentsSection({ businessId, documents, available, onChange }) {
  const [busy, setBusy] = useState("");
  const [problem, setProblem] = useState("");
  const [rejecting, setRejecting] = useState(null);
  const [note, setNote] = useState("");
  const byKind = Object.fromEntries(documents.map((d) => [d.kind, d]));

  if (!available) {
    return (
      <Section title="Verification documents" description="The business's registration and the owner's photo ID.">
        <div className="wiz-note">
          Document storage isn't set up yet. Apply <strong>sql/zella_onboarding.sql</strong>, then upload the documents here.
          Until then setup can be finished without them.
        </div>
      </Section>
    );
  }

  async function upload(kind, file) {
    setProblem("");
    if (!file) return;
    if (!DOCUMENT_TYPES.includes(file.type)) return setProblem("Upload a PDF, JPG, PNG, WEBP or HEIC file.");
    if (file.size > DOCUMENT_MAX_BYTES) return setProblem("Files must be 10 MB or smaller.");
    setBusy(kind);
    try {
      const meta = { businessId, kind, fileName: file.name, mimeType: file.type, size: file.size };
      const { path, token } = await callOwnerFunction("setup_document_upload_url", meta);
      const { error } = await supabase.storage.from("business-documents").uploadToSignedUrl(path, token, file, { contentType: file.type });
      if (error) throw new Error(error.message || "The upload didn't finish.");
      const { document } = await callOwnerFunction("setup_document_confirm", { ...meta, path });
      onChange([document, ...documents.filter((d) => d.kind !== kind)]);
    } catch (err) {
      setProblem(err.message);
    } finally {
      setBusy("");
    }
  }

  async function view(doc) {
    setProblem("");
    try {
      const { url } = await callOwnerFunction("document_view", { documentId: doc.id });
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (err) {
      setProblem(err.message);
    }
  }

  async function review(doc, status) {
    setProblem("");
    setBusy(doc.kind);
    try {
      const { document } = await callOwnerFunction("document_review", { documentId: doc.id, status, note: status === "rejected" ? note : "" });
      onChange(documents.map((d) => (d.id === doc.id ? document : d)));
      setRejecting(null);
      setNote("");
    } catch (err) {
      setProblem(err.message);
    } finally {
      setBusy("");
    }
  }

  return (
    <Section
      title="Verification documents"
      description="Proof that the business is real and that the person registering it may act for it. Files are private: only Zella admins can open them, through a link that expires after a minute."
      aside={<Badge tone={DOCUMENT_KINDS.filter((k) => k.required).every((k) => byKind[k.kind] && byKind[k.kind].status !== "rejected") ? "success" : "neutral"}>
        {DOCUMENT_KINDS.filter((k) => k.required && byKind[k.kind] && byKind[k.kind].status !== "rejected").length} of {DOCUMENT_KINDS.filter((k) => k.required).length} required uploaded
      </Badge>}
    >
      {problem && <div className="owner-form-error" role="alert">{problem}</div>}
      <div className="wiz-docs">
        {DOCUMENT_KINDS.map((k) => {
          const doc = byKind[k.kind];
          const [tone, label] = doc ? DOC_STATUS[doc.status] ?? ["neutral", doc.status] : [k.required ? "danger" : "neutral", k.required ? "Required" : "Optional"];
          return (
            <div key={k.kind} className={`wiz-doc ${doc ? `has ${doc.status}` : ""}`}>
              <div className="wiz-doc-main">
                <span className="wiz-doc-icon" aria-hidden="true"><Icon name={k.kind === "owner_identity" ? "badge" : "description"} /></span>
                <div>
                  <strong>{k.label}{k.required ? " *" : ""}</strong>
                  <small>{doc ? `${doc.file_name} · ${Math.max(1, Math.round(doc.size_bytes / 1024))} KB` : k.hint}</small>
                  {doc?.status === "rejected" && doc.review_note && <small className="wiz-doc-note">Rejected: {doc.review_note}</small>}
                </div>
                <Badge tone={tone}>{label}</Badge>
              </div>
              <div className="wiz-doc-actions">
                <label className={`owner-secondary-button wiz-upload ${busy === k.kind ? "busy" : ""}`}>
                  <input type="file" accept={DOCUMENT_TYPES.join(",")} disabled={Boolean(busy)} onChange={(e) => { upload(k.kind, e.target.files?.[0]); e.target.value = ""; }} />
                  {busy === k.kind ? "Uploading…" : doc ? "Replace" : "Upload"}
                </label>
                {doc && <button type="button" className="wiz-link" onClick={() => view(doc)}>View</button>}
                {doc && doc.status !== "verified" && <button type="button" className="wiz-link" disabled={Boolean(busy)} onClick={() => review(doc, "verified")}>Mark verified</button>}
                {doc && doc.status !== "rejected" && <button type="button" className="wiz-link-danger" disabled={Boolean(busy)} onClick={() => { setRejecting(doc.id); setNote(""); }}>Reject</button>}
              </div>
              {rejecting === doc?.id && (
                <div className="wiz-doc-reject">
                  <input value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} placeholder="Why? e.g. the name doesn't match the business" aria-label="Reason for rejecting" />
                  <button type="button" className="owner-secondary-button" onClick={() => setRejecting(null)}>Cancel</button>
                  <button type="button" className="owner-primary-button" disabled={!note.trim() || Boolean(busy)} onClick={() => review(doc, "rejected")}>Reject</button>
                </div>
              )}
            </div>
          );
        })}
      </div>
      <p className="wiz-hint">PDF or photo, up to 10 MB. Both required documents must be uploaded before setup can be finished.</p>
    </Section>
  );
}

// ---------------------------------------------------------------------------
// Hours & services (adapts to the industry)
// ---------------------------------------------------------------------------

function DetailInput({ field, value, onChange }) {
  if (field.type === "yesno") {
    return (
      <div className="wiz-segment" role="group" aria-label={field.label}>
        {[[true, "Yes"], [false, "No"]].map(([v, label]) => (
          <button key={label} type="button" className={value === v ? "on" : ""} aria-pressed={value === v} onClick={() => onChange(value === v ? "" : v)}>{label}</button>
        ))}
      </div>
    );
  }
  if (field.type === "select") {
    return (
      <select value={value ?? ""} onChange={(e) => onChange(e.target.value)}>
        <option value="">Not set</option>
        {field.options.map(([v, label]) => <option key={v} value={v}>{label}</option>)}
      </select>
    );
  }
  if (field.type === "number") {
    return <input type="number" inputMode="numeric" min={field.min} max={field.max} value={value ?? ""} onChange={(e) => onChange(e.target.value === "" ? "" : Number(e.target.value))} />;
  }
  if (field.type === "time") return <input type="time" value={value ?? ""} onChange={(e) => onChange(e.target.value)} />;
  return <input value={value ?? ""} placeholder={field.placeholder} onChange={(e) => onChange(e.target.value)} />;
}

function OperationsStep({ value, onChange, config, terminology, industryName }) {
  const services = termFor(terminology, "services");
  const setHours = (day, patch) => onChange({ ...value, hours: { ...value.hours, [day]: { ...value.hours[day], ...patch } } });
  const copyMonday = () => {
    const mon = value.hours.mon;
    onChange({ ...value, hours: Object.fromEntries(DAYS.map(([day]) => [day, day === "mon" || value.hours[day].closed ? value.hours[day] : { ...mon }])) });
  };
  const setDetail = (key, v) => onChange({ ...value, details: { ...value.details, [key]: v } });
  const setBooking = (key, v) => onChange({ ...value, booking: { ...value.booking, [key]: v } });

  return (
    <>
      <Section title="Opening hours" description="Used everywhere: when the AI books, when it says you're closed, and when follow-ups are allowed to go out.">
        <div className="wiz-hours">
          {DAYS.map(([day, label]) => {
            const h = value.hours[day];
            return (
              <div className={`wiz-hours-row ${h.closed ? "closed" : ""}`} key={day}>
                <strong>{label}</strong>
                <label className="wiz-inline-check">
                  <input type="checkbox" checked={h.closed} onChange={(e) => setHours(day, { closed: e.target.checked })} />
                  Closed
                </label>
                <input type="time" aria-label={`${label} opens`} value={h.open} disabled={h.closed} onChange={(e) => setHours(day, { open: e.target.value })} />
                <span>to</span>
                <input type="time" aria-label={`${label} closes`} value={h.close} disabled={h.closed} onChange={(e) => setHours(day, { close: e.target.value })} />
              </div>
            );
          })}
        </div>
        <button type="button" className="wiz-link wiz-gap-top" onClick={copyMonday} disabled={!value.hours.mon.open || !value.hours.mon.close}>Copy Monday's hours to every open day</button>
      </Section>

      <Section title={`About ${industryName ? `this ${industryName.toLowerCase()} business` : "the business"}`} description="Real facts only. The AI repeats them to callers.">
        <div className="owner-form-grid">
          <Field label="Short description" full>
            <textarea value={value.about} onChange={(e) => onChange({ ...value, about: e.target.value })} placeholder="What the business does, who it serves and what makes it different." />
          </Field>
          {config.details.map((field) => (
            <Field key={field.key} label={field.label} required={field.required} hint={field.hint || (field.type === "list" ? "Separate with commas" : undefined)} bare={field.type === "yesno"}>
              <DetailInput field={field} value={value.details[field.key]} onChange={(v) => setDetail(field.key, v)} />
            </Field>
          ))}
        </div>
      </Section>

      {config.appointments && (
        <Section title={`${termFor(terminology, "appointment")} preferences`} description="How the AI and the online booking offer times.">
          <div className="owner-form-grid">
            <Field label={`Usual length of a ${termFor(terminology, "appointment").toLowerCase()}`}>
              <select value={value.booking.defaultMinutes} onChange={(e) => setBooking("defaultMinutes", Number(e.target.value))}>
                {LENGTH_OPTIONS.map(([v, label]) => <option key={v} value={v}>{label}</option>)}
              </select>
            </Field>
            <Field label="Gap between bookings">
              <select value={value.booking.bufferMinutes} onChange={(e) => setBooking("bufferMinutes", Number(e.target.value))}>
                {[[0, "None"], [5, "5 min"], [10, "10 min"], [15, "15 min"], [30, "30 min"]].map(([v, label]) => <option key={v} value={v}>{label}</option>)}
              </select>
            </Field>
            <Field label="Shortest notice">
              <select value={value.booking.minNoticeHours} onChange={(e) => setBooking("minNoticeHours", Number(e.target.value))}>
                {[[0, "No minimum"], [1, "1 hour"], [2, "2 hours"], [4, "4 hours"], [24, "1 day"], [48, "2 days"]].map(([v, label]) => <option key={v} value={v}>{label}</option>)}
              </select>
            </Field>
            <Field label="Book up to">
              <select value={value.booking.maxDaysAhead} onChange={(e) => setBooking("maxDaysAhead", Number(e.target.value))}>
                {[[7, "1 week ahead"], [14, "2 weeks ahead"], [30, "1 month ahead"], [60, "2 months ahead"], [90, "3 months ahead"], [180, "6 months ahead"]].map(([v, label]) => <option key={v} value={v}>{label}</option>)}
              </select>
            </Field>
          </div>
        </Section>
      )}

      <Section title={services} description={config.servicesHint}>
        <ListEditor
          items={value.services}
          onChange={(items) => onChange({ ...value, services: items })}
          addLabel={`Add ${termFor(terminology, "service").toLowerCase()}`}
          emptyText={`No ${services.toLowerCase()} added yet. The AI won't describe ones that aren't listed.`}
          fields={[
            { key: "name", label: "Name", required: true },
            { key: "price", label: "Price", placeholder: "Leave empty if the AI shouldn't quote it" },
            { key: "duration", label: "Duration", placeholder: "e.g. 45 minutes" },
            { key: "description", label: "Description", full: true, multiline: true },
          ]}
        />
      </Section>
    </>
  );
}

// ---------------------------------------------------------------------------
// Team (optional)
// ---------------------------------------------------------------------------

function TeamStep({ value, onChange, config, terminology, showErrors }) {
  const staffWord = termFor(terminology, "staff");
  const plural = termFor(terminology, "staff_plural");
  const set = (i, patch) => onChange(value.map((m, n) => (n === i ? { ...m, ...patch } : m)));
  return (
    <Section
      title={plural}
      description={config.teamHint}
      aside={<Badge tone={config.team === "recommended" ? "success" : "neutral"}>{config.team === "recommended" ? "Recommended" : "Optional"}</Badge>}
    >
      {value.length === 0 && (
        <div className="wiz-empty wiz-empty-rich">
          <Icon name="groups" />
          <strong>No {plural.toLowerCase()} added</strong>
          <span>You can skip this. Without a team, bookings use the business's opening hours.</span>
        </div>
      )}
      <div className="wiz-list">
        {value.map((m, i) => (
          <div className="wiz-list-item" key={m.id || `new-${i}`}>
            <div className="owner-form-grid">
              <Field label="Name" required><input value={m.name} onChange={(e) => set(i, { name: e.target.value })} /></Field>
              <Field label="Role"><input value={m.title} placeholder={`e.g. ${staffWord}`} onChange={(e) => set(i, { title: e.target.value })} /></Field>
              <Field label="Phone" bare><PhoneField value={m.phone} onChange={(phone) => set(i, { phone })} showErrors={showErrors} label={`${m.name || "Team member"} phone`} /></Field>
              <Field label="Email" bare><EmailField value={m.email} onChange={(email) => set(i, { email })} showErrors={showErrors} placeholder="name@business.com" /></Field>
            </div>
            <button type="button" className="wiz-link-danger" onClick={() => onChange(value.filter((_, n) => n !== i))}>Remove</button>
          </div>
        ))}
        <button type="button" className="owner-secondary-button" onClick={() => onChange([...value, { id: "", name: "", title: "", phone: "", email: "" }])}>
          ＋ Add {staffWord.toLowerCase()}
        </button>
      </div>
      <p className="wiz-hint">Each person works the opening hours until their own hours are set in the CRM. Removing someone here switches them off; past bookings keep their name.</p>
    </Section>
  );
}

// ---------------------------------------------------------------------------
// Automations (on/off, then optional fine-tuning) and CRM setup (optional)
// ---------------------------------------------------------------------------

function AutomationsCombinedStep(props) {
  return (
    <>
      <AutomationSwitchesStep {...props} />
      <details className="wiz-advanced">
        <summary><span>Fine-tune timing and channels</span><small>Optional. The usual settings for the industry are already chosen.</small></summary>
        <AutomationsStep value={props.value} onChange={props.onChange} terminology={props.terminology} industryName={props.industryName} />
      </details>
    </>
  );
}

function CrmSetupStep({ terminology, onTerminology, modules, onModules }) {
  const changed = Object.keys(terminology.overrides || {}).length;
  return (
    <>
      <div className="wiz-note">
        This business already has its industry's modules and words. Change them only if it works differently.
      </div>
      <details className="wiz-advanced">
        <summary><span>Modules</span><small>{modules.filter((m) => m.enabled).length} of {modules.length} switched on</small></summary>
        <ModulesStep modules={modules} onChange={onModules} />
      </details>
      <details className="wiz-advanced">
        <summary><span>Words used in the CRM</span><small>{changed ? `${changed} changed from the industry's` : "Industry defaults"}</small></summary>
        <TerminologyStep value={terminology} onChange={onTerminology} />
      </details>
    </>
  );
}

// ---------------------------------------------------------------------------
// Spam protection (part of Phone & integrations): only the channels this business has
// ---------------------------------------------------------------------------

function SpamSection({ value, onChange, modules, config, available }) {
  const on = (slug) => modules.some((m) => m.slug === slug && m.enabled);
  const has = { call: on("calls") || on("ai-receptionist"), sms: on("sms"), email: on("email"), booking: config.appointments && on("calendar") };
  const set = (k, v) => onChange({ ...value, [k]: v });
  const row = (k, label, hint) => (
    <div className="wiz-spam-row">
      <div><strong>{label}</strong><small>{hint}</small></div>
      <Toggle checked={Boolean(value[k])} label={label} disabled={!value.enabled} onChange={(v) => set(k, v)} />
    </div>
  );
  if (!available) {
    return (
      <Section title="Spam protection" description="Screens spam calls, texts, emails and fake bookings.">
        <div className="wiz-note">Spam protection isn't set up on Zella yet (apply sql/zella_spam_protection.sql). Zella's platform limits still apply.</div>
      </Section>
    );
  }
  return (
    <Section
      title="Spam protection"
      description="On by default with safe settings. Zella's platform rules and limits always apply, whatever is chosen here."
      aside={<Toggle checked={value.enabled} label="Spam protection" onChange={(v) => set("enabled", v)} />}
    >
      {!value.enabled && <div className="wiz-note">Off: only Zella's platform-wide rules and limits will protect this business.</div>}
      {value.enabled && (
        <>
          {has.call && (
            <div className="wiz-spam-row">
              <div><strong>Suspicious callers</strong><small>Repeated calls, withheld numbers and blocked numbers are checked before the AI helps them.</small></div>
              <select value={value.call_screening} onChange={(e) => set("call_screening", e.target.value)} aria-label="Suspicious callers">
                <option value="flag">Answer and flag for review</option>
                <option value="screen">Screen: the AI doesn't help them</option>
              </select>
            </div>
          )}
          {has.call && value.call_screening === "screen" && (
            <div className="wiz-spam-row">
              <div><strong>When a call is screened, the AI</strong><small>Blocked numbers are always ended politely.</small></div>
              <select value={value.ai_spam_handling} onChange={(e) => set("ai_spam_handling", e.target.value)} aria-label="When screened">
                <option value="end_politely">Ends the call politely</option>
                <option value="take_message">Takes a short message only</option>
              </select>
            </div>
          )}
          {has.sms && row("sms_monitoring", "Watch incoming texts", "Floods, suspicious links and spam wording. No automatic replies to blocked senders.")}
          {has.email && row("email_monitoring", "Watch incoming email", "Floods, suspicious links and the email provider's own spam verdict.")}
          {has.booking && row("booking_protection", "Hold suspicious bookings", "Too many bookings from one contact, or a blocked contact: kept as a request for the team to confirm.")}
          {has.booking && value.booking_protection && (
            <div className="wiz-spam-row">
              <div><strong>Bookings allowed per contact per day</strong><small>Team bookings are never limited.</small></div>
              <input type="number" min={1} max={20} value={value.booking_daily_limit} aria-label="Bookings per contact per day"
                onChange={(e) => set("booking_daily_limit", Math.max(1, Math.min(20, Number(e.target.value) || 1)))} />
            </div>
          )}
          {row("notify_high_risk", "Alert the team about high-risk activity", "A few alerts an hour at most, without message content.")}
          <details className="wiz-spam-more">
            <summary>More options</summary>
            {row("auto_restrict", "Temporarily restrict clear abuse", "Only with two or more signals at high risk, for 24 hours, on that channel. Never permanent.")}
            {has.call && (
              <div className="wiz-spam-row">
                <div><strong>Flag repeated calls after</strong><small>Calls from one number within an hour.</small></div>
                <input type="number" min={2} max={50} value={value.repeat_call_limit} aria-label="Repeated calls"
                  onChange={(e) => set("repeat_call_limit", Math.max(2, Math.min(50, Number(e.target.value) || 2)))} />
              </div>
            )}
          </details>
          {!has.sms && !has.email && <p className="wiz-hint">Text and email checks appear here once those modules are switched on.</p>}
        </>
      )}
    </Section>
  );
}

function ReviewStep({ setup, industries, goTo, config, docsReady }) {
  const r = setup.receptionist;
  const o = setup.operations;
  const industry = industries.find((i) => i.id === setup.business.industryId);
  const enabledModules = setup.modules.filter((m) => m.enabled);
  const enabledAutomations = Object.values(setup.automations).filter((a) => a.enabled).length + setup.industryRules.filter((x) => x.enabled).length;
  const leads = Object.entries(setup.integrations.leadSources).filter(([, on]) => on).map(([k]) => ({ meta: "Meta", website: "Website", google: "Google" })[k]);
  const openDays = DAYS.filter(([day]) => !o.hours[day].closed && o.hours[day].open).length;
  const missing = missingDetails(config, o.details);
  const docs = DOCUMENT_KINDS.filter((k) => k.required).map((k) => ({ ...k, doc: setup.documents.find((d) => d.kind === k.kind) }));
  const verified = docs.every((d) => d.doc?.status === "verified");

  const rows = [
    { key: "business", title: "Business", ok: Boolean(setup.business.name && industry), required: true,
      detail: [setup.business.name, industry?.name, setup.business.city, setup.business.timezone].filter(Boolean).join(" · ") },
    { key: "owner", title: "Owner", ok: Boolean(setup.owner.name && setup.owner.email), required: true,
      detail: setup.owner.email ? `${setup.owner.name} · ${setup.owner.email}` : "Not added" },
    { key: "owner", title: "Verification documents", ok: docsReady, required: setup.documentsAvailable,
      detail: !setup.documentsAvailable ? "Document storage not set up yet (apply sql/zella_onboarding.sql)"
        : docs.map((d) => `${d.label}: ${d.doc ? ({ pending_review: "waiting for review", verified: "verified", rejected: "rejected" })[d.doc.status] : "missing"}`).join(" · ") },
    { key: "operations", title: "Hours & services", ok: openDays > 0 && missing.length === 0, required: true,
      detail: `${openDays} open day${openDays === 1 ? "" : "s"} · ${o.services.length} ${termFor(setup.terminology, o.services.length === 1 ? "service" : "services").toLowerCase()}${missing.length ? ` · missing ${missing.join(", ")}` : ""}` },
    { key: "team", title: termFor(setup.terminology, "staff_plural"), ok: setup.team.length > 0,
      detail: setup.team.length ? setup.team.map((m) => m.name).join(", ") : config.team === "recommended" ? "None yet (recommended)" : "None (optional)" },
    { key: "receptionist", title: "AI receptionist", ok: r.faqs.length > 0 || o.services.length > 0,
      detail: `${r.name} · ${r.faqs.length} FAQs · ${r.capabilities.length} abilities` },
    { key: "integrations", title: "Phone & integrations", ok: true,
      detail: `${setup.integrations.phone.mode === "new_number" ? "New Zella number" : `Call forwarding from ${setup.integrations.phone.existingNumber || "number not set"}`} · calendar ${setup.integrations.calendar} · leads ${leads.length ? leads.join(", ") : "none"}` },
    { key: "integrations", title: "Spam protection", ok: true,
      detail: !setup.spamAvailable ? "Not set up on Zella yet" : setup.spam.enabled ? `On · suspicious callers ${setup.spam.call_screening === "screen" ? "screened" : "flagged"}` : "Off (platform rules still apply)" },
    { key: "automations", title: "Automations", ok: true, detail: `${enabledAutomations} turned on (paused until go-live)` },
    { key: "crm", title: "CRM setup", ok: enabledModules.length > 0,
      detail: `${enabledModules.length} modules · ${termFor(setup.terminology, "customers")}, ${termFor(setup.terminology, "appointments")}` },
  ];
  const blocking = rows.filter((row) => row.required && !row.ok);

  return (
    <>
      <Section title="Review setup" description="Required items must be complete. Everything else can be finished later by you or the business owner."
        aside={<Badge tone={blocking.length ? "danger" : "success"}>{blocking.length ? `${blocking.length} to finish` : "Ready to finish"}</Badge>}>
        <div className="wiz-review">
          {rows.map((row) => (
            <div key={row.title} className="wiz-review-row">
              <span className={`wiz-review-dot ${row.ok ? "ok" : row.required ? "missing" : "later"}`}>
                {row.ok ? "✓" : row.required ? "!" : "–"}
              </span>
              <div>
                <strong>{row.title}{row.required ? " *" : ""}</strong>
                <span>{row.detail}</span>
              </div>
              <button type="button" className="wiz-link" onClick={() => goTo(STEP[row.key])}>Edit</button>
            </div>
          ))}
        </div>
      </Section>
      <div className="wiz-note">
        Finishing makes the workspace active with its industry's modules and words, and emails the owner their invitation.
        {setup.documentsAvailable && !verified && <> The documents stay <strong>waiting for review</strong> until an admin marks them verified.</>}
        {" "}The AI receptionist stays <strong>off</strong> until its phone number and voice agent are connected and tested,
        and automations stay paused until the business goes live.
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Wizard
// ---------------------------------------------------------------------------

export default function CreateBusinessWizard({ businessId: initialBusinessId, industries, onClose }) {
  const [setup, setSetup] = useState(emptySetup);
  const [businessId, setBusinessId] = useState(initialBusinessId || null);
  const [step, setStep] = useState(0);
  const [loading, setLoading] = useState(Boolean(initialBusinessId));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [showErrors, setShowErrors] = useState(false);
  const [result, setResult] = useState(null);

  const locked = ["testing", "ready", "active"].includes(setup.onboardingStatus);
  const top = useRef(null);

  // Each step opens at its top, not where the previous step's Save button was.
  useEffect(() => {
    top.current?.scrollIntoView?.({ block: "start", behavior: window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  }, [step]);

  async function reload(id, jump) {
    const data = await callOwnerFunction("setup_load", { businessId: id });
    const next = fromServer(data, industries);
    setSetup(next);
    if (jump) setStep(RESUME_STEP[next.onboardingStatus] ?? 0);
    return next;
  }

  useEffect(() => {
    if (!initialBusinessId) return;
    let active = true;
    reload(initialBusinessId, true)
      .catch((err) => active && setError(friendlyError(err)))
      .finally(() => active && setLoading(false));
    return () => { active = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialBusinessId]);

  // Changing an answer clears the last "fix this" message, so it never describes a problem that's gone.
  const update = (key) => (value) => { setError(""); setSetup((current) => ({ ...current, [key]: value })); };

  // Picking an industry also picks that industry's usual automations. The wording
  // (terminology) follows from the industry on the next save.
  const changeBusiness = (business) =>
    setError("") || setSetup((current) => {
      if (business.industryId === current.business.industryId) return { ...current, business };
      const industry = industries.find((i) => i.id === business.industryId);
      const cfg = onboardingFor(industry?.slug);
      // A new industry brings its usual automations, booking length and AI abilities; earlier answers to the
      // old industry's own questions no longer apply.
      return {
        ...current, business, automations: automationDefaultsFor(industry?.name), automationsFromIndustry: industry?.name || "",
        operations: { ...current.operations, details: {}, booking: { ...current.operations.booking, defaultMinutes: cfg.defaultLength } },
        receptionist: { ...current.receptionist, capabilities: cfg.capabilities },
      };
    });

  const industry = industries.find((i) => i.id === setup.business.industryId);
  const config = onboardingFor(industry?.slug);
  const requiredDocs = DOCUMENT_KINDS.filter((k) => k.required);
  const docsReady = !setup.documentsAvailable || requiredDocs.every((k) => setup.documents.some((d) => d.kind === k.kind && d.status !== "rejected"));

  function validate() {
    const key = STEPS[step].key;
    if (key === "business") {
      if (!setup.business.name.trim()) return "Enter the business name.";
      if (!setup.business.industryId) return "Select an industry.";
      if (checkEmail(setup.business.email)) return `Business email: ${checkEmail(setup.business.email)}`;
      if (validatePhone(setup.business.phone)) return `Business phone: ${validatePhone(setup.business.phone)}`;
      if (checkUrl(setup.business.website)) return `Website: ${checkUrl(setup.business.website)}`;
    }
    if (key === "owner") {
      if (!setup.owner.name.trim() || !setup.owner.email.trim()) return "Enter the owner's name and email.";
      if (checkEmail(setup.owner.email, { required: true })) return `Owner email: ${checkEmail(setup.owner.email, { required: true })}`;
      if (validatePhone(setup.owner.phone)) return `Owner phone: ${validatePhone(setup.owner.phone)}`;
    }
    if (key === "operations") {
      const hours = setup.operations.hours;
      const label = Object.fromEntries(DAYS);
      for (const [day] of DAYS) {
        const h = hours[day];
        if (h.closed || (!h.open && !h.close)) continue;
        if (!h.open || !h.close) return `${label[day]}: enter both the opening and the closing time, or mark it closed.`;
        if (h.close <= h.open) return `${label[day]}: the closing time must be after the opening time.`;
      }
      if (!DAYS.some(([day]) => !hours[day].closed && hours[day].open)) return "Enter the opening hours for at least one day.";
      const missing = missingDetails(config, setup.operations.details);
      if (missing.length) return `Fill in: ${missing.join(", ")}.`;
      const bad = config.details.find((d) => d.type === "number" && setup.operations.details[d.key] !== "" && setup.operations.details[d.key] !== undefined
        && (setup.operations.details[d.key] < (d.min ?? -Infinity) || setup.operations.details[d.key] > (d.max ?? Infinity)));
      if (bad) return `${bad.label}: enter a number from ${bad.min} to ${bad.max}.`;
    }
    if (key === "team") {
      for (const m of setup.team) {
        if (!m.name.trim() && (m.title || m.phone || m.email)) return "Every team member needs a name, or remove the empty row.";
        if (checkEmail(m.email)) return `${m.name || "Team member"} email: ${checkEmail(m.email)}`;
        if (validatePhone(m.phone)) return `${m.name || "Team member"} phone: ${validatePhone(m.phone)}`;
      }
    }
    if (key === "receptionist") {
      if (validatePhone(setup.receptionist.escalation.transferTo.phone)) return `Transfer phone number: ${validatePhone(setup.receptionist.escalation.transferTo.phone)}`;
      if (setup.receptionist.faqs.some((f) => f.question.trim() && !f.answer.trim())) return "Answer every FAQ, or remove the ones without an answer.";
    }
    if (key === "integrations") {
      if (validatePhone(setup.integrations.transferNumber)) return `Call transfer number: ${validatePhone(setup.integrations.transferNumber)}`;
      if (setup.integrations.phone.mode === "call_forwarding") {
        if (!setup.integrations.phone.existingNumber.trim()) return "Enter the business number that will be forwarded to Zella.";
        const bad = validatePhone(setup.integrations.phone.existingNumber, { required: true });
        if (bad) return `Business number to forward: ${bad}`;
      }
    }
    return "";
  }

  async function saveCurrentStep() {
    const key = STEPS[step].key;

    if (key === "business") {
      const data = await callOwnerFunction("setup_save_business", { businessId, business: setup.business });
      setBusinessId(data.businessId);
      await reload(data.businessId, false);
      return;
    }

    if (key === "owner") {
      await callOwnerFunction("setup_save_owner", { businessId, owner: setup.owner });
      await reload(businessId, false);
      return;
    }

    if (key === "operations") {
      const o = setup.operations;
      const details = config.details
        .map((d) => {
          const raw = o.details[d.key];
          const value = d.type === "select" ? d.options.find(([v]) => v === raw)?.[1] ?? "" : raw;
          return { key: d.key, label: d.label, value: value === undefined || value === null ? "" : value };
        })
        .filter((d) => d.value !== "");
      await callOwnerFunction("setup_save_operations", {
        businessId,
        operations: { hours: o.hours, about: o.about, services: o.services, details, booking: o.booking, appointments: config.appointments },
      });
      return;
    }

    if (key === "team") {
      await callOwnerFunction("setup_save_team", { businessId, team: setup.team.filter((m) => m.name.trim()) });
      await reload(businessId, false); // new team members get their ids
      return;
    }

    if (key === "crm") {
      await callOwnerFunction("setup_save_modules", {
        businessId,
        enabledModuleIds: setup.modules.filter((m) => m.enabled).map((m) => m.id),
      });
      await callOwnerFunction("setup_save_terminology", { businessId, overrides: setup.terminology.overrides });
      return;
    }

    if (key === "receptionist") {
      const r = setup.receptionist;
      // Hours, services and business facts are saved on the Hours & services step, not here.
      const { hours: _h, services: _s, about: _a, serviceArea: _sa, ...rest } = r;
      await callOwnerFunction("setup_save_receptionist", {
        businessId,
        receptionist: {
          ...rest,
          faqs: r.faqs.filter((f) => f.question.trim() && f.answer.trim()),
          restrictions: r.restrictions.split("\n").map((line) => line.trim()).filter(Boolean),
        },
      });
      return;
    }

    if (key === "integrations") {
      await callOwnerFunction("setup_save_integrations", { businessId, integrations: setup.integrations });
      if (setup.spamAvailable) await callOwnerFunction("setup_save_spam", { businessId, spam: setup.spam });
      return;
    }

    if (key === "automations") {
      await callOwnerFunction("setup_save_automations", { businessId, automations: setup.automations, industryRules: setup.industryRules });
    }
  }

  async function run(after) {
    const problem = validate();
    if (problem) {
      setError(problem);
      setShowErrors(true);
      return;
    }
    setShowErrors(false);

    setSaving(true);
    setError("");
    try {
      await saveCurrentStep();
      after();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setSaving(false);
    }
  }

  async function finish() {
    setSaving(true);
    setError("");
    try {
      const data = await callOwnerFunction("setup_finish", { businessId });
      setResult(data);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setSaving(false);
    }
  }

  const goTo = (index) => {
    if (index > 0 && !businessId) return;
    setError("");
    setStep(index);
    setShowErrors(false);
  };

  if (loading) {
    return (
      <section className="wiz">
        <div className="owner-empty-state"><strong>Loading business setup...</strong></div>
      </section>
    );
  }

  if (result) {
    const sent = result.invitationStatus === "sent" || result.invitationStatus === "accepted";
    return (
      <section className="wiz">
        <div className="wiz-done">
          <div className={`wiz-done-icon ${sent ? "" : "warn"}`}>{sent ? "✓" : "!"}</div>
          <h2>{setup.business.name} is set up</h2>
          <p>The workspace is active. The AI receptionist stays off until its phone number and voice agent are connected.</p>
          <div className="wiz-done-grid">
            <div><span>Workspace</span><Badge tone="success">Active</Badge></div>
            <div><span>Owner invitation</span><Badge tone={sent ? "success" : "danger"}>{result.invitationStatus}</Badge></div>
            <div><span>AI receptionist</span><Badge>Off until connected</Badge></div>
            <div><span>Automations</span><Badge>Paused until go-live</Badge></div>
          </div>
          {result.invitationError && <div className="owner-form-error">Invitation not sent: {result.invitationError}</div>}
          {result.warning && <div className="owner-form-error">{result.warning}</div>}
          <div className="wiz-done-actions">
            {!sent && (
              <button type="button" className="owner-secondary-button" onClick={finish} disabled={saving}>
                {saving ? "Retrying..." : "Retry invitation"}
              </button>
            )}
            <button type="button" className="owner-primary-button" onClick={() => onClose(true)}>
              Back to businesses
            </button>
          </div>
        </div>
      </section>
    );
  }

  const isLast = step === STEPS.length - 1;
  const terminology = setup.terminology;

  return (
    <section className="wiz" ref={top}>
      <div className="wiz-header">
        <div>
          <div className="owner-eyebrow">{businessId ? "BUSINESS SETUP" : "NEW BUSINESS"}</div>
          <h1>{setup.business.name || "Create a business"}</h1>
          <p>Set up the CRM, AI receptionist, integrations and automations for this client.</p>
        </div>
        <button type="button" className="owner-secondary-button" onClick={() => onClose(Boolean(businessId))} disabled={saving}>
          Close
        </button>
      </div>

      <div className="wiz-progress" role="progressbar" aria-label="Setup progress" aria-valuemin={1} aria-valuemax={STEPS.length} aria-valuenow={step + 1}>
        <span style={{ width: `${((step + 1) / STEPS.length) * 100}%` }} />
        <small>Step {step + 1} of {STEPS.length} · {STEPS[step].label}</small>
      </div>

      <ol className="wiz-stepper">
        {STEPS.map((item, index) => (
          <li key={item.key}>
            <button
              type="button"
              className={`${index === step ? "current" : ""} ${index < step ? "done" : ""}`}
              onClick={() => goTo(index)}
              disabled={saving || (index > 0 && !businessId)}
            >
              <span className="wiz-step-num">{index < step ? "✓" : index + 1}</span>
              <span className="wiz-step-label">{item.label}</span>
            </button>
          </li>
        ))}
      </ol>

      <div className="wiz-body" key={step}>
        {STEPS[step].key === "business" && (
          <BusinessStep value={setup.business} onChange={changeBusiness} industries={industries} isExisting={Boolean(businessId)} locked={locked} showErrors={showErrors} />
        )}
        {STEPS[step].key === "owner" && (
          <>
            <OwnerStep value={setup.owner} onChange={update("owner")} invitation={setup.invitation} showErrors={showErrors} />
            <DocumentsSection businessId={businessId} documents={setup.documents} available={setup.documentsAvailable} onChange={update("documents")} />
          </>
        )}
        {STEPS[step].key === "operations" && <OperationsStep value={setup.operations} onChange={update("operations")} config={config} terminology={terminology} industryName={industry?.name} />}
        {STEPS[step].key === "team" && <TeamStep value={setup.team} onChange={update("team")} config={config} terminology={terminology} showErrors={showErrors} />}
        {STEPS[step].key === "receptionist" && <ReceptionistStep value={setup.receptionist} onChange={update("receptionist")} terminology={terminology} showErrors={showErrors} faqPrompts={config.faqPrompts} />}
        {STEPS[step].key === "integrations" && (
          <>
            <IntegrationsStep value={setup.integrations} onChange={update("integrations")} showErrors={showErrors} />
            <SpamSection value={setup.spam} onChange={update("spam")} modules={setup.modules} config={config} available={setup.spamAvailable} />
          </>
        )}
        {STEPS[step].key === "automations" && <AutomationsCombinedStep value={setup.automations} onChange={update("automations")} rules={setup.industryRules} onRules={update("industryRules")} terminology={terminology} industryName={industry?.name} />}
        {STEPS[step].key === "crm" && <CrmSetupStep terminology={terminology} onTerminology={update("terminology")} modules={setup.modules} onModules={update("modules")} />}
        {STEPS[step].key === "review" && <ReviewStep setup={setup} industries={industries} goTo={goTo} config={config} docsReady={docsReady} />}
      </div>

      {error && <div className="owner-form-error wiz-error" role="alert">{error}</div>}

      <div className="wiz-footer">
        <button type="button" className="owner-secondary-button" onClick={() => goTo(step - 1)} disabled={saving || step === 0}>
          ← Back
        </button>
        <div className="wiz-footer-right">
          {!isLast && businessId && (
            <button type="button" className="owner-secondary-button" disabled={saving} onClick={() => run(() => onClose(true))}>
              Save & exit
            </button>
          )}
          {isLast ? (
            <button
              type="button"
              className="owner-primary-button"
              onClick={finish}
              disabled={saving || !setup.owner.email || !docsReady}
            >
              {saving ? "Finishing..." : setup.invitation?.status === "sent" || setup.invitation?.status === "accepted" ? "Save & finish" : "Finish & send invitation"}
            </button>
          ) : (
            <button type="button" className="owner-primary-button" disabled={saving} onClick={() => run(() => setStep(step + 1))}>
              {saving ? "Saving..." : step === 0 && !businessId ? "Create draft & continue →" : "Save & continue →"}
            </button>
          )}
        </div>
      </div>
    </section>
  );
}
