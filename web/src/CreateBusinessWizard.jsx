import { automationDefaultsFor, emptyAutomations } from "./industryAutomations";
import { EmailField, PhoneField, TimeZoneSelect } from "./formFields";
import { checkEmail, countryList, validatePhone } from "./formValidation";
import { useEffect, useMemo, useState } from "react";
import "./CreateBusinessWizard.css";
import { supabase } from "./supabase";

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

const STEPS = [
  { key: "business", label: "Business" },
  { key: "switches", label: "Automations" },
  { key: "owner", label: "Owner" },
  { key: "terminology", label: "Terminology" },
  { key: "modules", label: "Modules" },
  { key: "receptionist", label: "AI receptionist" },
  { key: "integrations", label: "Phone & integrations" },
  { key: "automations", label: "Automation options" },
  { key: "review", label: "Review" },
];

const RESUME_STEP = {
  started: 0,
  business_info: 1,
  owner_setup: 3,
  industry_setup: 4,
  ai_setup: 6,
  communications_setup: 7,
  automation_setup: 8,
  testing: 8,
  ready: 8,
  active: 8,
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
  for (const row of data.automations || []) {
    if (setup.automations[row.trigger_type]) {
      setup.automations[row.trigger_type] = {
        enabled: row.status !== "disabled",
        settings: { ...setup.automations[row.trigger_type].settings, ...row.trigger_config },
      };
    }
  }

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
  return <span className={`wiz-badge wiz-badge-${tone}`}>{children}</span>;
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
          <Field label="Website" full>
            <input value={value.website} onChange={set("website")} placeholder="https://" />
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

function ReceptionistStep({ value, onChange, terminology, showErrors }) {
  const set = (key) => (event) => onChange({ ...value, [key]: event.target.value });
  const services = termFor(terminology, "services");

  const setHours = (day, patch) =>
    onChange({ ...value, hours: { ...value.hours, [day]: { ...value.hours[day], ...patch } } });

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

      <Section title="About the business">
        <div className="owner-form-grid">
          <Field label="Business description" full hint="Only real facts. The AI repeats this to callers.">
            <textarea value={value.about} onChange={set("about")} />
          </Field>
          <Field label="Service area" full>
            <input value={value.serviceArea} onChange={set("serviceArea")} placeholder="e.g. Austin and surrounding areas" />
          </Field>
        </div>
      </Section>

      <Section title="Business hours" description="Days left blank are saved as 'not set', so the AI won't guess.">
        <div className="wiz-hours">
          {DAYS.map(([day, label]) => {
            const h = value.hours[day];
            return (
              <div className="wiz-hours-row" key={day}>
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
      </Section>

      <Section title={services} description={`The ${services.toLowerCase()} the AI can talk about.`}>
        <ListEditor
          items={value.services}
          onChange={(items) => onChange({ ...value, services: items })}
          addLabel={`Add ${termFor(terminology, "service").toLowerCase()}`}
          emptyText={`No ${services.toLowerCase()} added yet.`}
          fields={[
            { key: "name", label: "Name", required: true },
            { key: "price", label: "Price", placeholder: "Leave empty if the AI shouldn't quote it" },
            { key: "duration", label: "Duration", placeholder: "e.g. 45 minutes" },
            { key: "description", label: "Description", full: true, multiline: true },
          ]}
        />
      </Section>

      <Section title="FAQs" description="Questions customers often ask, with the business's real answers.">
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
          <Field label="Call transfer number" hint="Where the AI sends calls it shouldn't handle">
            <input type="tel" value={value.transferNumber} onChange={(e) => onChange({ ...value, transferNumber: e.target.value })} placeholder="+1 (555) 000-0000" />
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

const SWITCHES = [
  ["appointment_reminder", (a) => `${a} reminders`, (a) => `Remind customers before their ${a}.`],
  ["appointment_confirmation", () => "Confirmation & check-in", (a) => `Ask customers to confirm their ${a}.`],
  ["no_show_follow_up", () => "No-show follow-up", (a) => `Reach out when someone misses their ${a} and offer to rebook.`],
  ["missed_call_follow_up", () => "Missed-call recovery", () => "Call back anyone whose call was missed."],
  ["new_lead_callback", () => "New lead callback", () => "Call new leads from Meta, the website and other sources."],
  ["post_appointment_follow_up", (a) => `After-${a.toLowerCase()} follow-up`, () => "Thank customers and ask for feedback."],
  ["quote_follow_up", () => "Quote follow-up", () => "Check in with people who were sent a quote and haven't replied."],
  ["lead_reactivation", () => "Win back quiet customers", () => "Reach out to people you haven't heard from in a while."],
  ["waitlist_offer", () => "Waitlist offers", (a) => `When ${/^[aeiou]/i.test(a) ? "an" : "a"} ${a} opens up, offer it to people waiting.`],
  ["staff_unavailable", () => "Team member unavailable", (a) => `Offer another time when a ${a} can't go ahead.`],
];

// Step 2: switch each automation on or off. The choices start from what's usual for the industry.
function AutomationSwitchesStep({ value, onChange, terminology, industryName }) {
  const appt = termFor(terminology, "appointment").toLowerCase();
  const setAll = (enabled) => onChange(Object.fromEntries(Object.entries(value).map(([type, item]) => [type, { ...item, enabled }])));
  const setOne = (type, enabled) => onChange({ ...value, [type]: { ...value[type], enabled } });
  const onCount = SWITCHES.filter(([type]) => value[type]?.enabled).length;
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
        <p className="wiz-hint">{onCount} of {SWITCHES.length} on. They start running when the business goes live.</p>
        <div className="wiz-automation-list">
          {SWITCHES.map(([type, title, text]) => (
            <div key={type} className={`wiz-automation ${value[type]?.enabled ? "on" : ""}`}>
              <div className="wiz-module-top">
                <div>
                  <strong>{title(termFor(terminology, "appointment"))}</strong>
                  <p>{text(appt)}</p>
                </div>
                <Toggle checked={Boolean(value[type]?.enabled)} label={title(termFor(terminology, "appointment"))} onChange={(enabled) => setOne(type, enabled)} />
              </div>
            </div>
          ))}
        </div>
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

function ReviewStep({ setup, industries, goTo }) {
  const r = setup.receptionist;
  const industry = industries.find((i) => i.id === setup.business.industryId);
  const enabledModules = setup.modules.filter((m) => m.enabled);
  const enabledAutomations = Object.values(setup.automations).filter((a) => a.enabled).length;
  const leads = Object.entries(setup.integrations.leadSources).filter(([, on]) => on).map(([k]) => ({ meta: "Meta", website: "Website", google: "Google" })[k]);
  const hoursSet = Object.values(r.hours).some((h) => h.closed || h.open);

  const rows = [
    { step: 0, title: "Business", ok: Boolean(setup.business.name && industry), required: true,
      detail: [setup.business.name, industry?.name && `${industry.name} CRM`, setup.business.timezone].filter(Boolean).join(" · ") },
    { step: 2, title: "Owner", ok: Boolean(setup.owner.name && setup.owner.email), required: true,
      detail: setup.owner.email ? `${setup.owner.name} · ${setup.owner.email}` : "Not added" },
    { step: 3, title: "Terminology", ok: true,
      detail: `${termFor(setup.terminology, "customers")}, ${termFor(setup.terminology, "staff_plural")}, ${termFor(setup.terminology, "appointments")}` },
    { step: 4, title: "Modules", ok: enabledModules.length > 0,
      detail: enabledModules.length ? enabledModules.map((m) => m.name).join(", ") : "None enabled" },
    { step: 5, title: "AI receptionist", ok: r.services.length > 0 || r.faqs.length > 0,
      detail: `${r.services.length} ${termFor(setup.terminology, "services").toLowerCase()} · ${r.faqs.length} FAQs · hours ${hoursSet ? "set" : "not set"}` },
    { step: 6, title: "Phone & integrations", ok: true,
      detail: `${setup.integrations.phone.mode === "new_number" ? "New Zella number" : `Call forwarding from ${setup.integrations.phone.existingNumber || "number not set"}`} · calendar ${setup.integrations.calendar} · leads ${leads.length ? leads.join(", ") : "none"}` },
    { step: 7, title: "Automations", ok: true, detail: `${enabledAutomations} turned on (paused until go-live)` },
  ];

  return (
    <>
      <Section title="Review setup" description="Required items must be complete. Everything else can be finished later by you or the business owner.">
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
              <button type="button" className="wiz-link" onClick={() => goTo(row.step)}>Edit</button>
            </div>
          ))}
        </div>
      </Section>
      <div className="wiz-note">
        Finishing makes the workspace active and emails the owner their invitation. The AI receptionist stays
        <strong> off</strong> until its phone number and voice agent are connected and tested.
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
      .catch((err) => active && setError(err.message))
      .finally(() => active && setLoading(false));
    return () => { active = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialBusinessId]);

  const update = (key) => (value) => setSetup((current) => ({ ...current, [key]: value }));

  // Picking an industry also picks that industry's usual automations. The wording
  // (terminology) follows from the industry on the next save.
  const changeBusiness = (business) =>
    setSetup((current) => {
      if (business.industryId === current.business.industryId) return { ...current, business };
      const name = industries.find((i) => i.id === business.industryId)?.name;
      return { ...current, business, automations: automationDefaultsFor(name), automationsFromIndustry: name || "" };
    });

  function validate() {
    if (step === 0) {
      if (!setup.business.name.trim()) return "Enter the business name.";
      if (!setup.business.industryId) return "Select an industry.";
      if (checkEmail(setup.business.email)) return `Business email: ${checkEmail(setup.business.email)}`;
      if (validatePhone(setup.business.phone)) return `Business phone: ${validatePhone(setup.business.phone)}`;
    }
    if (step === 2) {
      if (!setup.owner.name.trim() || !setup.owner.email.trim()) return "Enter the owner's name and email.";
      if (checkEmail(setup.owner.email, { required: true })) return `Owner email: ${checkEmail(setup.owner.email, { required: true })}`;
      if (validatePhone(setup.owner.phone)) return `Owner phone: ${validatePhone(setup.owner.phone)}`;
    }
    if (step === 5 && validatePhone(setup.receptionist.escalation.transferTo.phone)) {
      return `Transfer phone number: ${validatePhone(setup.receptionist.escalation.transferTo.phone)}`;
    }
    if (step === 6 && setup.integrations.phone.mode === "call_forwarding") {
      if (!setup.integrations.phone.existingNumber.trim()) return "Enter the business number that will be forwarded to Zella.";
      const bad = validatePhone(setup.integrations.phone.existingNumber, { required: true });
      if (bad) return `Business number to forward: ${bad}`;
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

    if (key === "terminology") {
      await callOwnerFunction("setup_save_terminology", { businessId, overrides: setup.terminology.overrides });
      return;
    }

    if (key === "modules") {
      await callOwnerFunction("setup_save_modules", {
        businessId,
        enabledModuleIds: setup.modules.filter((m) => m.enabled).map((m) => m.id),
      });
      return;
    }

    if (key === "receptionist") {
      const r = setup.receptionist;
      await callOwnerFunction("setup_save_receptionist", {
        businessId,
        receptionist: {
          ...r,
          restrictions: r.restrictions.split("\n").map((line) => line.trim()).filter(Boolean),
        },
      });
      return;
    }

    if (key === "integrations") {
      await callOwnerFunction("setup_save_integrations", { businessId, integrations: setup.integrations });
      return;
    }

    if (key === "switches") {
      // Saved quietly: it doesn't move the setup progress forward, so a draft reopens where it was left.
      await callOwnerFunction("setup_save_automations", { businessId, automations: setup.automations, early: true });
      return;
    }

    if (key === "automations") {
      await callOwnerFunction("setup_save_automations", { businessId, automations: setup.automations });
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
      setError(err.message);
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
      setError(err.message);
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
    <section className="wiz">
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

      <div className="wiz-body">
        {step === 0 && (
          <BusinessStep value={setup.business} onChange={changeBusiness} industries={industries} isExisting={Boolean(businessId)} locked={locked} showErrors={showErrors} />
        )}
        {step === 1 && <AutomationSwitchesStep value={setup.automations} onChange={update("automations")} terminology={terminology} industryName={industries.find((i) => i.id === setup.business.industryId)?.name} />}
        {step === 2 && <OwnerStep value={setup.owner} onChange={update("owner")} invitation={setup.invitation} showErrors={showErrors} />}
        {step === 3 && <TerminologyStep value={terminology} onChange={update("terminology")} />}
        {step === 4 && <ModulesStep modules={setup.modules} onChange={update("modules")} />}
        {step === 5 && <ReceptionistStep value={setup.receptionist} onChange={update("receptionist")} terminology={terminology} showErrors={showErrors} />}
        {step === 6 && <IntegrationsStep value={setup.integrations} onChange={update("integrations")} showErrors={showErrors} />}
        {step === 7 && <AutomationsStep value={setup.automations} onChange={update("automations")} terminology={terminology} industryName={industries.find((i) => i.id === setup.business.industryId)?.name} />}
        {step === 8 && <ReviewStep setup={setup} industries={industries} goTo={goTo} />}
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
              disabled={saving || !setup.owner.email}
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
