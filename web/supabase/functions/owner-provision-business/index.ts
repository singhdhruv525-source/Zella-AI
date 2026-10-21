import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(data: unknown, status = 200) {
  return Response.json(data, {
    status,
    headers: corsHeaders,
  });
}

// ---------------------------------------------------------------------------
// Input helpers: everything from the browser is cleaned before it is stored.
// ---------------------------------------------------------------------------

type Json = Record<string, unknown>;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^[0-9+()\-.\s]{7,30}$/;

function text(value: unknown, max = 500): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function bool(value: unknown, fallback = false): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function obj(value: unknown): Json {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Json)
    : {};
}

function list(value: unknown, max: number): unknown[] {
  return Array.isArray(value) ? value.slice(0, max) : [];
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return allowed.includes(value as T) ? (value as T) : fallback;
}

function numberIn(value: unknown, allowed: readonly number[], fallback: number): number {
  return allowed.includes(Number(value)) ? Number(value) : fallback;
}

function validTimezone(timezone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: timezone });
    return true;
  } catch {
    return false;
  }
}

class InputError extends Error {
  status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

function requireId(value: unknown, label = "business"): string {
  const id = text(value, 64);
  if (!UUID_RE.test(id)) throw new InputError(`A valid ${label} is required`);
  return id;
}

function optionalPhone(value: unknown, label: string): string {
  const phone = text(value, 30);
  if (phone && !PHONE_RE.test(phone)) {
    throw new InputError(`Enter a valid ${label}`);
  }
  return phone;
}

// ---------------------------------------------------------------------------
// Setup definitions
// ---------------------------------------------------------------------------

const TERMINOLOGY_KEYS = [
  "customer", "customers", "staff", "staff_plural", "service", "services",
  "appointment", "appointments", "job", "jobs", "visit", "visits",
] as const;

const PERSONALITIES = ["professional", "friendly", "warm", "casual", "premium"] as const;
const LANGUAGES = ["en-US", "es-US", "en-US+es-US"] as const;

const CAPABILITIES = [
  "answer_questions", "answer_calls", "handle_sms", "send_emails",
  "book_appointments", "reschedule_appointments", "cancel_appointments",
  "collect_customer_info", "follow_up_leads", "take_messages",
] as const;

const ESCALATION_TRIGGERS = [
  "customer_requests_human", "unknown_answer", "upset_customer",
  "emergency", "sensitive_issue", "complex_request", "billing_question",
] as const;

const TRANSFER_TYPES = ["owner", "manager", "team_member", "phone_number"] as const;
const DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] as const;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

const MODULE_DEPENDENCIES: Record<string, string[]> = {
  "ai-receptionist": ["calls"],
  "ai-appointments": ["calendar"],
  "ai-follow-up": ["automations"],
  "ai-sales": ["calls"],
  "ai-support": ["calls"],
};

// Automations managed by the setup wizard. n8n runs them once they are active.
const AUTOMATIONS = {
  appointment_reminder: {
    name: "Appointment reminders",
    description: "Reminds customers before their appointment.",
    actions: [{ type: "send_reminder" }],
    settings: (s: Json) => ({
      hours_before: list(s.hours_before, 4)
        .map(Number)
        .filter((n) => [1, 2, 4, 24, 48].includes(n)),
      channel: oneOf(s.channel, ["sms", "call", "sms_and_call"] as const, "sms"),
    }),
  },
  appointment_confirmation: {
    name: "Appointment confirmation",
    description: "Asks customers to confirm or check in for their appointment.",
    actions: [{ type: "request_confirmation" }],
    settings: (s: Json) => ({
      hours_before: numberIn(s.hours_before, [24, 48, 72], 24),
      channel: oneOf(s.channel, ["sms", "call"] as const, "sms"),
    }),
  },
  no_show_follow_up: {
    name: "No-show follow-up",
    description: "Contacts customers who missed their appointment to rebook.",
    actions: [{ type: "no_show_outreach" }],
    settings: (s: Json) => ({
      minutes_after: numberIn(s.minutes_after, [10, 15, 30, 60], 15),
      channel: oneOf(s.channel, ["sms", "call"] as const, "call"),
    }),
  },
  missed_call_follow_up: {
    name: "Missed-call recovery",
    description: "Calls back customers whose call was missed.",
    actions: [{ type: "ai_callback" }],
    settings: (s: Json) => ({
      minutes_after: numberIn(s.minutes_after, [0, 5, 15, 30], 5),
      max_attempts: numberIn(s.max_attempts, [1, 2, 3], 2),
      fallback_sms: bool(s.fallback_sms, true),
    }),
  },
  new_lead_callback: {
    name: "New lead callback",
    description: "Calls new leads from Meta, the website and other lead sources.",
    actions: [{ type: "ai_callback" }],
    settings: (s: Json) => ({
      minutes_after: numberIn(s.minutes_after, [0, 5, 15, 60], 5),
      max_attempts: numberIn(s.max_attempts, [1, 2, 3], 2),
      retry_after_hours: numberIn(s.retry_after_hours, [1, 4, 24], 24),
      fallback_sms: bool(s.fallback_sms, true),
    }),
  },
  post_appointment_follow_up: {
    name: "After-appointment follow-up",
    description: "Thanks customers and asks for feedback after their appointment.",
    actions: [{ type: "post_visit_message" }],
    settings: (s: Json) => ({
      hours_after: numberIn(s.hours_after, [2, 24, 72], 24),
      channel: oneOf(s.channel, ["sms", "email"] as const, "sms"),
    }),
  },
} as const;

type AutomationType = keyof typeof AUTOMATIONS;
const AUTOMATION_TYPES = Object.keys(AUTOMATIONS) as AutomationType[];

// ---------------------------------------------------------------------------
// Setup actions
// ---------------------------------------------------------------------------

async function getBusiness(admin: SupabaseClient, businessId: string) {
  const { data, error } = await admin
    .from("businesses")
    .select("*")
    .eq("id", businessId)
    .maybeSingle();

  if (error) throw error;
  if (!data) throw new InputError("Business not found", 404);
  return data;
}

async function getReceptionist(admin: SupabaseClient, businessId: string) {
  const { data: agent, error } = await admin
    .from("ai_agents")
    .select("id, name, status")
    .eq("business_id", businessId)
    .eq("agent_type", "receptionist")
    .order("is_default", { ascending: false })
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (error) throw error;
  if (!agent) throw new InputError("This business has no AI receptionist", 409);

  const { data: config, error: configError } = await admin
    .from("ai_agent_configs")
    .select("*")
    .eq("agent_id", agent.id)
    .maybeSingle();

  if (configError) throw configError;
  return { agent, config };
}

async function advance(admin: SupabaseClient, businessId: string, status: string) {
  const { error } = await admin.rpc("zella_advance_onboarding", {
    p_business_id: businessId,
    p_status: status,
  });
  if (error) throw error;
}

async function mergeSetupData(
  admin: SupabaseClient,
  businessId: string,
  key: string,
  value: unknown,
) {
  const business = await getBusiness(admin, businessId);
  const setupData = { ...obj(business.setup_data), [key]: value };

  const { error } = await admin
    .from("businesses")
    .update({ setup_data: setupData, updated_at: new Date().toISOString() })
    .eq("id", businessId);

  if (error) throw error;
}

async function loadSetup(admin: SupabaseClient, businessId: string) {
  const business = await getBusiness(admin, businessId);

  const [configResult, modulesResult, enabledResult, invitationResult, automationsResult] =
    await Promise.all([
      admin
        .from("industry_configurations")
        .select("terminology")
        .eq("industry_id", business.industry_id)
        .maybeSingle(),
      admin
        .from("industry_modules")
        .select("id, name, slug, description")
        .eq("industry_id", business.industry_id)
        .eq("is_active", true)
        .order("name"),
      admin
        .from("business_modules")
        .select("module_id, enabled")
        .eq("business_id", businessId),
      admin
        .from("business_invitations")
        .select("id, email, owner_name, status, invited_at, accepted_at, last_error")
        .eq("business_id", businessId)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle(),
      admin
        .from("automations")
        .select("trigger_type, name, status, trigger_config")
        .eq("business_id", businessId)
        .in("trigger_type", AUTOMATION_TYPES),
    ]);

  const queryError = configResult.error ?? modulesResult.error ??
    enabledResult.error ?? invitationResult.error ?? automationsResult.error;
  if (queryError) throw queryError;

  const { agent, config } = await getReceptionist(admin, businessId);
  const enabled = new Set(
    (enabledResult.data ?? []).filter((row) => row.enabled).map((row) => row.module_id),
  );

  return {
    business,
    invitation: invitationResult.data ?? null,
    terminology: {
      industry: obj(configResult.data?.terminology),
      overrides: obj(business.terminology_overrides),
    },
    modules: (modulesResult.data ?? []).map((module) => ({
      ...module,
      enabled: enabled.has(module.id),
    })),
    receptionist: {
      agentId: agent.id,
      name: agent.name,
      status: agent.status,
      personality: config?.personality ?? "",
      tone: config?.tone ?? "",
      capabilities: config?.capabilities ?? [],
      knowledgeBase: obj(config?.knowledge_base),
      escalationRules: obj(config?.escalation_rules),
      appointmentRules: obj(config?.appointment_rules),
      voiceConfig: obj(config?.voice_config),
    },
    automations: automationsResult.data ?? [],
  };
}

function cleanBusinessFields(fields: Json) {
  const values = {
    name: text(fields.name, 200),
    legal_name: text(fields.legalName, 200),
    industry_id: text(fields.industryId, 64),
    email: text(fields.email, 254).toLowerCase(),
    phone: optionalPhone(fields.phone, "business phone number"),
    website: text(fields.website, 300),
    address_line_1: text(fields.addressLine1, 200),
    address_line_2: text(fields.addressLine2, 200),
    city: text(fields.city, 120),
    state: text(fields.state, 120),
    postal_code: text(fields.postalCode, 20),
    country: text(fields.country, 2).toUpperCase() || "US",
    timezone: text(fields.timezone, 64) || "America/New_York",
  };

  if (!values.name) throw new InputError("Business name is required");
  if (!UUID_RE.test(values.industry_id)) throw new InputError("Select an industry");
  if (values.email && !EMAIL_RE.test(values.email)) {
    throw new InputError("Enter a valid business email");
  }
  if (!validTimezone(values.timezone)) throw new InputError("Select a valid timezone");

  return values;
}

async function saveBusiness(admin: SupabaseClient, fields: Json) {
  const values = cleanBusinessFields(obj(fields.business));
  const existingId = text(fields.businessId, 64);

  if (!existingId) {
    const { data, error } = await admin.rpc("zella_create_business_draft", {
      p_fields: values,
    });

    if (error) {
      if (error.message.includes("INDUSTRY_NOT_FOUND")) {
        throw new InputError("The selected industry is not available");
      }
      throw error;
    }

    return { businessId: data.business_id, created: true, industryChanged: false, values };
  }

  const businessId = requireId(existingId);
  const business = await getBusiness(admin, businessId);

  const industryChanged = business.industry_id !== values.industry_id;

  if (industryChanged) {
    if (["testing", "ready", "active"].includes(business.onboarding_status)) {
      throw new InputError(
        "The industry can't be changed after setup is finished",
        409,
      );
    }

    const { error } = await admin.rpc("zella_change_business_industry", {
      p_business_id: businessId,
      p_industry_id: values.industry_id,
    });
    if (error) throw error;
  }

  const { industry_id: _industry, ...rest } = values;
  const update = Object.fromEntries(
    Object.entries(rest).map(([key, value]) => [key, value === "" ? null : value]),
  );

  const { error } = await admin
    .from("businesses")
    .update({ ...update, updated_at: new Date().toISOString() })
    .eq("id", businessId);
  if (error) throw error;

  return { businessId, created: false, industryChanged, values };
}

async function saveOwner(admin: SupabaseClient, fields: Json, adminUserId: string) {
  const businessId = requireId(fields.businessId);
  const owner = obj(fields.owner);
  const ownerName = text(owner.name, 200);
  const ownerEmail = text(owner.email, 254).toLowerCase();
  const ownerPhone = optionalPhone(owner.phone, "owner phone number");

  if (!ownerName || !ownerEmail) {
    throw new InputError("Owner name and email are required");
  }
  if (!EMAIL_RE.test(ownerEmail)) {
    throw new InputError("Enter a valid owner email address");
  }

  await getBusiness(admin, businessId);

  const { data: current, error: currentError } = await admin
    .from("business_invitations")
    .select("id, email, status")
    .eq("business_id", businessId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (currentError) throw currentError;

  const alreadySent = current && ["sent", "accepted"].includes(current.status);

  if (alreadySent && current.email !== ownerEmail) {
    throw new InputError(
      "An invitation was already sent to a different email. The owner email can't be changed here.",
      409,
    );
  }

  const { data: elsewhere, error: elsewhereError } = await admin
    .from("business_invitations")
    .select("id")
    .eq("email", ownerEmail)
    .neq("business_id", businessId)
    .in("status", ["pending", "sent"])
    .limit(1);
  if (elsewhereError) throw elsewhereError;

  if (elsewhere?.length) {
    throw new InputError(
      "This email already has a pending invitation for another business",
      409,
    );
  }

  const now = new Date().toISOString();

  if (current && !alreadySent) {
    const { error } = await admin
      .from("business_invitations")
      .update({
        email: ownerEmail,
        owner_name: ownerName,
        status: "pending",
        last_error: null,
        updated_at: now,
      })
      .eq("id", current.id);
    if (error) throw error;
  } else if (current && alreadySent) {
    const { error } = await admin
      .from("business_invitations")
      .update({ owner_name: ownerName, updated_at: now })
      .eq("id", current.id);
    if (error) throw error;
  } else {
    const { error } = await admin.from("business_invitations").insert({
      business_id: businessId,
      email: ownerEmail,
      owner_name: ownerName,
      invited_by: adminUserId,
      status: "pending",
    });
    if (error) throw error;
  }

  await mergeSetupData(admin, businessId, "owner", { phone: ownerPhone });
  await advance(admin, businessId, "owner_setup");
  return { businessId };
}

async function saveTerminology(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const input = obj(fields.overrides);
  const overrides: Record<string, string> = {};

  for (const key of TERMINOLOGY_KEYS) {
    const value = text(input[key], 60);
    if (value) overrides[key] = value;
  }

  await getBusiness(admin, businessId);

  const { error } = await admin
    .from("businesses")
    .update({ terminology_overrides: overrides, updated_at: new Date().toISOString() })
    .eq("id", businessId);
  if (error) throw error;

  await advance(admin, businessId, "industry_setup");
  return { businessId };
}

async function saveModules(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const requested = list(fields.enabledModuleIds, 100)
    .map((id) => text(id, 64))
    .filter((id) => UUID_RE.test(id));

  const business = await getBusiness(admin, businessId);

  const { data: modules, error: modulesError } = await admin
    .from("industry_modules")
    .select("id, slug, name")
    .eq("industry_id", business.industry_id)
    .eq("is_active", true);
  if (modulesError) throw modulesError;

  // Enforce dependencies on the server, not only in the UI.
  const enabled = new Set(requested);
  const bySlug = new Map((modules ?? []).map((m) => [m.slug, m]));

  for (const module of modules ?? []) {
    if (!enabled.has(module.id)) continue;
    for (const dependency of MODULE_DEPENDENCIES[module.slug] ?? []) {
      const required = bySlug.get(dependency);
      if (required && !enabled.has(required.id)) {
        throw new InputError(`${module.name} requires ${required.name}`);
      }
    }
  }

  const { data: count, error } = await admin.rpc("zella_set_business_modules", {
    p_business_id: businessId,
    p_enabled: [...enabled],
  });

  if (error) {
    if (error.message.includes("MODULE_NOT_AVAILABLE")) {
      throw new InputError("One of the selected modules isn't available for this industry");
    }
    throw error;
  }

  await advance(admin, businessId, "industry_setup");
  return { businessId, enabledModules: count };
}

async function saveReceptionist(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const input = obj(fields.receptionist);
  const business = await getBusiness(admin, businessId);
  const { agent, config } = await getReceptionist(admin, businessId);

  const services = list(input.services, 100)
    .map((item) => {
      const s = obj(item);
      return {
        name: text(s.name, 120),
        description: text(s.description, 600),
        price: text(s.price, 60),
        duration: text(s.duration, 60),
      };
    })
    .filter((s) => s.name);

  const faqs = list(input.faqs, 200)
    .map((item) => {
      const f = obj(item);
      return { question: text(f.question, 300), answer: text(f.answer, 2000) };
    })
    .filter((f) => f.question && f.answer);

  const policiesInput = obj(input.policies);
  const policies = Object.fromEntries(
    ["cancellation", "refund", "payment", "emergency", "appointment", "other"]
      .map((key) => [key, text(policiesInput[key], 2000)])
      .filter(([, value]) => value),
  );

  const hoursInput = obj(input.hours);
  const hours = Object.fromEntries(
    DAYS.map((day) => {
      const h = obj(hoursInput[day]);
      const open = text(h.open, 5);
      const close = text(h.close, 5);
      const closed = bool(h.closed, false);
      if (closed) return [day, { closed: true }];
      // Missing hours are stored as "not set", never guessed as open or closed.
      if (!TIME_RE.test(open) || !TIME_RE.test(close)) {
        return [day, { not_set: true }];
      }
      return [day, { closed: false, open, close }];
    }),
  );

  const escalationInput = obj(input.escalation);
  const transferInput = obj(escalationInput.transferTo);
  const transferPhone = optionalPhone(transferInput.phone, "transfer phone number");

  const capabilities = list(input.capabilities, 20)
    .filter((c): c is string => CAPABILITIES.includes(c as typeof CAPABILITIES[number]));

  const triggers = list(escalationInput.triggers, 20)
    .filter((t): t is string =>
      ESCALATION_TRIGGERS.includes(t as typeof ESCALATION_TRIGGERS[number])
    );

  const restrictions = list(input.restrictions, 50)
    .map((r) => text(r, 300))
    .filter(Boolean);

  const agentName = text(input.name, 80) || "AI Receptionist";
  const personality = oneOf(input.personality, PERSONALITIES, "professional");
  const now = new Date().toISOString();

  const { error: agentError } = await admin
    .from("ai_agents")
    .update({ name: agentName, updated_at: now })
    .eq("id", agent.id);
  if (agentError) throw agentError;

  const configValues = {
    personality,
    tone: text(input.instructions, 2000),
    capabilities,
    knowledge_base: {
      about: text(input.about, 3000),
      service_area: text(input.serviceArea, 500),
      hours,
      services,
      faqs,
      policies,
      restrictions,
    },
    escalation_rules: {
      triggers,
      transfer_to: {
        type: oneOf(transferInput.type, TRANSFER_TYPES, "owner"),
        name: text(transferInput.name, 120),
        phone: transferPhone,
      },
    },
    appointment_rules: {
      can_book: capabilities.includes("book_appointments"),
      can_reschedule: capabilities.includes("reschedule_appointments"),
      can_cancel: capabilities.includes("cancel_appointments"),
      notes: text(input.bookingNotes, 2000),
    },
    voice_config: {
      ...obj(config?.voice_config),
      greeting: text(input.greeting, 500),
      language: oneOf(input.language, LANGUAGES, "en-US"),
    },
    business_context: {
      ...obj(config?.business_context),
      business_name: business.name,
      industry_id: business.industry_id,
      timezone: business.timezone,
    },
    updated_at: now,
  };

  const { error: configError } = config
    ? await admin.from("ai_agent_configs").update(configValues).eq("id", config.id)
    : await admin.from("ai_agent_configs").insert({ agent_id: agent.id, ...configValues });
  if (configError) throw configError;

  await advance(admin, businessId, "ai_setup");
  return { businessId, services: services.length, faqs: faqs.length };
}

async function saveIntegrations(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const input = obj(fields.integrations);
  const phone = obj(input.phone);
  const leads = obj(input.leadSources);
  // Older drafts saved "existing_number"; that is now call forwarding.
  const savedMode = phone.mode === "existing_number" ? "call_forwarding" : phone.mode;
  const mode = oneOf(savedMode, ["new_number", "call_forwarding"] as const, "new_number");

  // Both options use a Zella (Telnyx) number: either customers call it
  // directly, or the business forwards its own number to it.
  const areaCode = text(phone.areaCode, 5);
  if (areaCode && !/^\d{3}$/.test(areaCode)) {
    throw new InputError("Area code must be 3 digits");
  }

  const forwardFrom = optionalPhone(phone.existingNumber, "business phone number");
  if (mode === "call_forwarding" && !forwardFrom) {
    throw new InputError("Enter the business number that will be forwarded to Zella");
  }

  // These are the client's setup choices. Real connections are stored in
  // the integrations table only after they are verified.
  const choices = {
    phone: {
      mode,
      area_code: areaCode,
      forward_from: mode === "call_forwarding" ? forwardFrom : "",
      forward_when: mode === "call_forwarding"
        ? oneOf(phone.forwardWhen, ["always", "no_answer", "busy_or_no_answer", "after_hours"] as const, "always")
        : "",
    },
    transfer_number: optionalPhone(input.transferNumber, "transfer phone number"),
    calendar: oneOf(input.calendar, ["google", "outlook", "none"] as const, "none"),
    email: oneOf(input.email, ["gmail", "outlook", "none"] as const, "none"),
    lead_sources: {
      meta: bool(leads.meta),
      website: bool(leads.website),
      google: bool(leads.google),
    },
  };

  await mergeSetupData(admin, businessId, "integrations", choices);
  await advance(admin, businessId, "communications_setup");
  return { businessId };
}

async function saveAutomations(
  admin: SupabaseClient,
  fields: Json,
  adminUserId: string,
) {
  const businessId = requireId(fields.businessId);
  const input = obj(fields.automations);
  await getBusiness(admin, businessId);

  const { data: existing, error: existingError } = await admin
    .from("automations")
    .select("id, trigger_type, status")
    .eq("business_id", businessId)
    .in("trigger_type", AUTOMATION_TYPES);
  if (existingError) throw existingError;

  const byType = new Map((existing ?? []).map((row) => [row.trigger_type, row]));
  const now = new Date().toISOString();

  for (const type of AUTOMATION_TYPES) {
    const definition = AUTOMATIONS[type];
    const item = obj(input[type]);
    const enabled = bool(item.enabled, false);
    const current = byType.get(type);

    // Enabled automations wait as "paused" until the business goes live.
    // A live automation that stays enabled keeps running.
    const status = !enabled
      ? "disabled"
      : current?.status === "active"
      ? "active"
      : "paused";

    const values = {
      name: definition.name,
      description: definition.description,
      trigger_type: type,
      status,
      trigger_config: definition.settings(obj(item.settings)),
      actions: definition.actions,
      conditions: {},
      updated_at: now,
    };

    const { error } = current
      ? await admin.from("automations").update(values).eq("id", current.id)
      : await admin.from("automations").insert({
        ...values,
        business_id: businessId,
        created_by: adminUserId,
      });
    if (error) throw error;
  }

  await advance(admin, businessId, "automation_setup");
  return { businessId };
}

async function finishSetup(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const business = await getBusiness(admin, businessId);

  const { data: invitation, error: invitationError } = await admin
    .from("business_invitations")
    .select("id, email, owner_name, status")
    .eq("business_id", businessId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (invitationError) throw invitationError;

  if (!invitation) {
    throw new InputError("Add the business owner before finishing setup");
  }

  const now = new Date().toISOString();

  // Workspace becomes active; the AI receptionist stays disabled until the
  // phone number and voice agent are connected and tested.
  const { error: activateError } = await admin
    .from("businesses")
    .update({ is_active: true, updated_at: now })
    .eq("id", businessId);
  if (activateError) throw activateError;

  await advance(admin, businessId, "testing");

  if (invitation.status === "sent" || invitation.status === "accepted") {
    return { businessId, invitationStatus: invitation.status };
  }

  const appUrl = Deno.env.get("ZELLA_APP_URL");
  const { data: invited, error: inviteError } =
    await admin.auth.admin.inviteUserByEmail(invitation.email, {
      data: { full_name: invitation.owner_name, business_id: businessId },
      ...(appUrl ? { redirectTo: appUrl } : {}),
    });

  if (inviteError || !invited?.user) {
    const reason = inviteError?.message ?? "Invitation email could not be sent";
    console.error("Owner invitation failed", inviteError);

    await admin
      .from("business_invitations")
      .update({ status: "failed", last_error: reason, updated_at: now })
      .eq("id", invitation.id);

    return {
      businessId,
      businessName: business.name,
      invitationStatus: "failed",
      invitationError: /already|registered|exists/i.test(reason)
        ? "This email already has a Zella account"
        : reason,
    };
  }

  const { error: sentError } = await admin
    .from("business_invitations")
    .update({
      status: "sent",
      auth_user_id: invited.user.id,
      invited_at: now,
      expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
      last_error: null,
      updated_at: now,
    })
    .eq("id", invitation.id);

  const { data: member, error: memberLookupError } = await admin
    .from("business_members")
    .select("id")
    .eq("business_id", businessId)
    .eq("user_id", invited.user.id)
    .maybeSingle();

  const { error: memberError } = memberLookupError
    ? { error: memberLookupError }
    : member
    ? { error: null }
    : await admin.from("business_members").insert({
      business_id: businessId,
      user_id: invited.user.id,
      role: "owner",
      status: "invited",
    });

  const followUpError = sentError ?? memberError;
  if (followUpError) {
    console.error("Invitation bookkeeping failed", followUpError);
    await admin
      .from("business_invitations")
      .update({ last_error: followUpError.message, updated_at: now })
      .eq("id", invitation.id);
  }

  return {
    businessId,
    businessName: business.name,
    invitationStatus: "sent",
    warning: followUpError
      ? "The invitation was sent, but the owner could not be linked to the business. Check the invitation record."
      : undefined,
  };
}

// ---------------------------------------------------------------------------
// Audit log
// ---------------------------------------------------------------------------

type AuditEntry = {
  action: string;
  business_id?: string | null;
  entity_type?: string | null;
  entity_id?: string | null;
  old_data?: Json | null;
  new_data?: Json | null;
};

type AuditContext = { userId: string; ip: string | null; userAgent: string | null };

// Audit failures are logged but never block the admin's action.
async function writeAudit(admin: SupabaseClient, ctx: AuditContext, entry: AuditEntry) {
  const { error } = await admin.from("audit_logs").insert({
    ...entry,
    user_id: ctx.userId,
    ip_address: ctx.ip,
    user_agent: ctx.userAgent,
  });
  if (error) console.error("Audit log write failed", error);
}

function requestContext(req: Request, userId: string): AuditContext {
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "";
  const ip = /^[0-9a-fA-F:.]{3,45}$/.test(forwarded) ? forwarded : null;
  return { userId, ip, userAgent: req.headers.get("user-agent")?.slice(0, 300) ?? null };
}

// What each setup action records. Large content (FAQs, policies) is
// summarised as counts so the log stays readable.
// deno-lint-ignore no-explicit-any
const AUDITED: Record<string, (fields: Json, result: any) => AuditEntry> = {
  setup_save_business: (_fields, r) => ({
    action: r.created
      ? "business.draft_created"
      : r.industryChanged
      ? "business.industry_changed"
      : "business.updated",
    business_id: r.businessId,
    entity_type: "business",
    entity_id: r.businessId,
    new_data: r.values,
  }),
  setup_save_owner: (fields, r) => {
    const owner = obj(fields.owner);
    return {
      action: "owner.saved",
      business_id: r.businessId,
      entity_type: "business_invitation",
      new_data: { name: text(owner.name, 200), email: text(owner.email, 254).toLowerCase() },
    };
  },
  setup_save_terminology: (fields, r) => ({
    action: "terminology.updated",
    business_id: r.businessId,
    entity_type: "business",
    entity_id: r.businessId,
    new_data: { overrides: obj(fields.overrides) },
  }),
  setup_save_modules: (_fields, r) => ({
    action: "modules.updated",
    business_id: r.businessId,
    entity_type: "business_modules",
    new_data: { enabled_modules: r.enabledModules },
  }),
  setup_save_receptionist: (fields, r) => ({
    action: "ai_receptionist.updated",
    business_id: r.businessId,
    entity_type: "ai_agent",
    new_data: {
      services: r.services,
      faqs: r.faqs,
      personality: text(obj(fields.receptionist).personality, 40),
    },
  }),
  setup_save_integrations: (fields, r) => {
    const input = obj(fields.integrations);
    return {
      action: "integrations.preferences_updated",
      business_id: r.businessId,
      entity_type: "business",
      entity_id: r.businessId,
      new_data: {
        phone_mode: text(obj(input.phone).mode, 40),
        calendar: text(input.calendar, 20),
        email: text(input.email, 20),
        lead_sources: obj(input.leadSources),
      },
    };
  },
  setup_save_automations: (fields, r) => ({
    action: "automations.updated",
    business_id: r.businessId,
    entity_type: "automations",
    new_data: {
      enabled: AUTOMATION_TYPES.filter((type) => bool(obj(obj(fields.automations)[type]).enabled)),
    },
  }),
  industry_save: (_fields, r) => ({
    action: "industry.updated",
    entity_type: "industry",
    entity_id: r.industryId,
    old_data: { name: r.name, terminology: r.previousTerminology },
    new_data: {
      name: r.name,
      terminology: r.terminology,
      modules_added: r.modulesCreated,
      modules_updated: r.modulesUpdated,
    },
  }),
  industry_create: (_fields, r) => ({
    action: "industry.created",
    entity_type: "industry",
    entity_id: r.industryId,
    new_data: { name: r.name, copied_from: r.copiedFrom, modules: r.modules },
  }),
  admin_invite: (_fields, r) => ({
    action: r.reactivated ? "admin.reactivated" : "admin.added",
    entity_type: "platform_admin",
    entity_id: r.targetUserId,
    new_data: { email: r.email, role: r.role, invitation_sent: r.invited },
  }),
  admin_update: (_fields, r) => ({
    action: "admin.updated",
    entity_type: "platform_admin",
    entity_id: r.targetUserId,
    old_data: r.before,
    new_data: r.after,
  }),
  ticket_create: (_fields, r) => ({
    action: "ticket.created",
    business_id: r.businessId,
    entity_type: "support_ticket",
    entity_id: r.ticketId,
    new_data: { subject: r.subject },
  }),
  ticket_update: (_fields, r) => ({
    action: "ticket.updated",
    business_id: r.businessId,
    entity_type: "support_ticket",
    entity_id: r.ticketId,
    new_data: r.changes,
  }),
  plan_save: (_fields, r) => ({
    action: r.created ? "plan.created" : "plan.updated",
    entity_type: "plan",
    entity_id: r.planId,
    old_data: r.before,
    new_data: r.after,
  }),
  business_suspend: (_fields, r) => ({
    action: "business.suspended",
    business_id: r.businessId,
    entity_type: "business",
    entity_id: r.businessId,
    new_data: { reason: r.reason || null },
  }),
  business_reactivate: (_fields, r) => ({
    action: "business.reactivated",
    business_id: r.businessId,
    entity_type: "business",
    entity_id: r.businessId,
  }),
  business_cancel: (_fields, r) => ({
    action: "business.cancellation_scheduled",
    business_id: r.businessId,
    entity_type: "business",
    entity_id: r.businessId,
    new_data: {
      cancel_at: r.cancelAt,
      reason: r.reason || null,
      continue_email: r.emailSent ? "sent to n8n" : `not sent: ${r.emailError}`,
    },
  }),
  business_undo_cancel: (_fields, r) => ({
    action: "business.cancellation_undone",
    business_id: r.businessId,
    entity_type: "business",
    entity_id: r.businessId,
    old_data: { cancel_at: r.previousCancelAt },
  }),
  invitation_resend: (_fields, r) => ({
    action: r.invitationStatus === "sent" ? "invitation.resent" : "invitation.failed",
    business_id: r.businessId,
    entity_type: "business_invitation",
    new_data: { email: r.email, status: r.invitationStatus, ...(r.invitationError ? { error: r.invitationError } : {}) },
  }),
  setup_finish: (_fields, r) => ({
    action: r.invitationStatus === "sent"
      ? "invitation.sent"
      : r.invitationStatus === "failed"
      ? "invitation.failed"
      : "setup.finished",
    business_id: r.businessId,
    entity_type: "business",
    entity_id: r.businessId,
    new_data: {
      invitation_status: r.invitationStatus,
      ...(r.invitationError ? { error: r.invitationError } : {}),
    },
  }),
};

async function resolveUsers(admin: SupabaseClient, ids: (string | null)[]) {
  const unique = [...new Set(ids.filter((id): id is string => Boolean(id)))].slice(0, 100);
  const entries = await Promise.all(
    unique.map(async (id) => {
      const { data } = await admin.auth.admin.getUserById(id);
      return [id, data?.user?.email ?? null] as const;
    }),
  );
  return Object.fromEntries(entries) as Record<string, string | null>;
}

async function businessNames(admin: SupabaseClient, ids: (string | null)[]) {
  const unique = [...new Set(ids.filter((id): id is string => Boolean(id)))];
  if (!unique.length) return {} as Record<string, string>;
  const { data, error } = await admin.from("businesses").select("id, name").in("id", unique);
  if (error) throw error;
  return Object.fromEntries((data ?? []).map((b) => [b.id, b.name])) as Record<string, string>;
}

// ---------------------------------------------------------------------------
// Admin pages: overview, business details, audit logs
// ---------------------------------------------------------------------------

const DRAFT_STATUSES = [
  "started", "business_info", "owner_setup", "industry_setup", "ai_setup",
  "communications_setup", "automation_setup",
];

async function overviewData(admin: SupabaseClient) {
  await processCancellations(admin);
  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const now = Date.now();

  const [
    businessesResult, industriesResult, invitationsResult, agentsResult,
    callsResult, aiCallsResult, ticketsResult, integrationsResult, logsResult,
  ] = await Promise.all([
    admin.from("businesses")
      .select("id, name, industry_id, onboarding_status, is_active, created_at, updated_at, suspended_at, cancel_at, cancelled_at")
      .order("updated_at", { ascending: false }),
    admin.from("industries").select("id, name"),
    admin.from("business_invitations")
      .select("id, business_id, email, status, expires_at, last_error, created_at"),
    admin.from("ai_agents").select("business_id, status").eq("agent_type", "receptionist"),
    admin.from("calls").select("id", { count: "exact", head: true }).gte("created_at", since),
    admin.from("calls").select("id", { count: "exact", head: true })
      .gte("created_at", since).eq("ai_handled", true),
    admin.from("support_tickets").select("id", { count: "exact", head: true })
      .in("status", ["open", "in_progress"]),
    admin.from("integrations")
      .select("id, business_id, provider, integration_type, status, error_message, updated_at")
      .in("status", ["error", "disconnected"]),
    admin.from("audit_logs")
      .select("id, action, business_id, user_id, entity_type, created_at")
      .order("created_at", { ascending: false })
      .limit(12),
  ]);

  const queryError = businessesResult.error ?? industriesResult.error ??
    invitationsResult.error ?? agentsResult.error ?? callsResult.error ??
    aiCallsResult.error ?? ticketsResult.error ?? integrationsResult.error ??
    logsResult.error;
  if (queryError) throw queryError;

  const businesses = businessesResult.data ?? [];
  const invitations = invitationsResult.data ?? [];
  const industryName = new Map((industriesResult.data ?? []).map((i) => [i.id, i.name]));
  const nameById = new Map(businesses.map((b) => [b.id, b.name]));

  // Suspended and cancelled businesses are counted separately, never as live or in setup.
  const running = businesses.filter((b) => !b.suspended_at && !b.cancelled_at);
  const count = (statuses: string[]) =>
    running.filter((b) => statuses.includes(b.onboarding_status)).length;
  const suspended = businesses.filter((b) => b.suspended_at && !b.cancelled_at);
  const cancelled = businesses.filter((b) => b.cancelled_at);
  const cancelling = businesses
    .filter((b) => b.cancel_at && !b.cancelled_at)
    .sort((a, b) => a.cancel_at.localeCompare(b.cancel_at));

  const expired = invitations.filter((i) =>
    i.status === "expired" ||
    (i.status === "sent" && i.expires_at && new Date(i.expires_at).getTime() < now)
  );

  const attention = [
    ...invitations.filter((i) => i.status === "failed").map((i) => ({
      kind: "invitation_failed",
      businessId: i.business_id,
      businessName: nameById.get(i.business_id) ?? "Unknown business",
      detail: i.last_error || `Invitation to ${i.email} failed`,
    })),
    ...expired.map((i) => ({
      kind: "invitation_expired",
      businessId: i.business_id,
      businessName: nameById.get(i.business_id) ?? "Unknown business",
      detail: `Invitation to ${i.email} expired`,
    })),
    ...(integrationsResult.data ?? []).map((i) => ({
      kind: "integration_error",
      businessId: i.business_id,
      businessName: nameById.get(i.business_id) ?? "Unknown business",
      detail: `${i.provider} ${i.status}${i.error_message ? `: ${i.error_message}` : ""}`,
    })),
    ...businesses.filter((b) => b.onboarding_status === "failed").map((b) => ({
      kind: "setup_failed",
      businessId: b.id,
      businessName: b.name,
      detail: "Setup marked as failed",
    })),
  ];

  const logs = logsResult.data ?? [];
  const actors = await resolveUsers(admin, logs.map((l) => l.user_id));

  return {
    stats: {
      totalBusinesses: businesses.length,
      setupsInProgress: count(DRAFT_STATUSES),
      setupComplete: count(["testing", "ready"]),
      live: count(["active"]),
      pendingInvitations: invitations.filter((i) => ["pending", "sent"].includes(i.status)).length - expired.filter((i) => i.status === "sent").length,
      acceptedInvitations: invitations.filter((i) => i.status === "accepted").length,
      receptionistsLive: (agentsResult.data ?? []).filter((a) => a.status === "active").length,
      callsLast30Days: callsResult.count ?? 0,
      aiCallsLast30Days: aiCallsResult.count ?? 0,
      openTickets: ticketsResult.count ?? 0,
      suspended: suspended.length,
      cancelling: cancelling.length,
      cancelled: cancelled.length,
    },
    funnel: [
      { label: "Draft", count: count(DRAFT_STATUSES) },
      { label: "Setup complete", count: count(["testing", "ready"]) },
      { label: "Live", count: count(["active"]) },
      { label: "Suspended", count: suspended.length },
      { label: "Cancelled", count: cancelled.length },
    ],
    upcomingCancellations: cancelling.slice(0, 8).map((b) => ({
      id: b.id,
      name: b.name,
      cancelAt: b.cancel_at,
    })),
    inProgress: running
      .filter((b) => DRAFT_STATUSES.includes(b.onboarding_status))
      .slice(0, 8)
      .map((b) => ({
        id: b.id,
        name: b.name,
        industry: industryName.get(b.industry_id) ?? "Unassigned",
        status: b.onboarding_status,
        updatedAt: b.updated_at,
      })),
    recentBusinesses: [...businesses]
      .sort((a, b) => b.created_at.localeCompare(a.created_at))
      .slice(0, 5)
      .map((b) => ({
        id: b.id,
        name: b.name,
        industry: industryName.get(b.industry_id) ?? "Unassigned",
        status: b.cancelled_at ? "cancelled" : b.suspended_at ? "suspended" : b.onboarding_status,
        createdAt: b.created_at,
      })),
    attention,
    activity: logs.map((l) => ({
      ...l,
      actor: actors[l.user_id] ?? null,
      business_name: l.business_id ? nameById.get(l.business_id) ?? null : null,
    })),
  };
}

async function businessDetail(admin: SupabaseClient, businessId: string) {
  const setup = await loadSetup(admin, businessId);

  const [
    industryResult, invitationsResult, membersResult, integrationsResult,
    callsResult, callCountResult, logsResult, ticketsResult,
  ] = await Promise.all([
    admin.from("industries").select("id, name").eq("id", setup.business.industry_id).maybeSingle(),
    admin.from("business_invitations")
      .select("id, email, owner_name, status, invited_at, accepted_at, expires_at, last_error, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: false }),
    admin.from("business_members")
      .select("user_id, role, status, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: true }),
    admin.from("integrations")
      .select("id, provider, integration_type, status, account_email, error_message, last_synced_at, updated_at")
      .eq("business_id", businessId),
    admin.from("calls")
      .select("id, direction, status, from_number, to_number, started_at, duration_seconds, ai_handled, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: false })
      .limit(10),
    admin.from("calls").select("id", { count: "exact", head: true }).eq("business_id", businessId),
    admin.from("audit_logs")
      .select("id, action, user_id, entity_type, new_data, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: false })
      .limit(30),
    admin.from("support_tickets")
      .select("id, subject, status, priority, category, created_at")
      .eq("business_id", businessId)
      .order("created_at", { ascending: false })
      .limit(10),
  ]);

  const queryError = industryResult.error ?? invitationsResult.error ??
    membersResult.error ?? integrationsResult.error ?? callsResult.error ??
    callCountResult.error ?? logsResult.error ?? ticketsResult.error;
  if (queryError) throw queryError;

  const members = membersResult.data ?? [];
  const logs = logsResult.data ?? [];
  const userIds = [...members.map((m) => m.user_id), ...logs.map((l) => l.user_id)];

  const [emails, profilesResult] = await Promise.all([
    resolveUsers(admin, userIds),
    members.length
      ? admin.from("profiles").select("id, first_name, last_name, phone")
        .in("id", members.map((m) => m.user_id))
      : Promise.resolve({ data: [], error: null }),
  ]);
  if (profilesResult.error) throw profilesResult.error;

  const profileById = new Map((profilesResult.data ?? []).map((p) => [p.id, p]));

  return {
    ...setup,
    industryName: industryResult.data?.name ?? "Unassigned",
    invitations: invitationsResult.data ?? [],
    members: members.map((m) => {
      const profile = profileById.get(m.user_id);
      return {
        ...m,
        email: emails[m.user_id] ?? null,
        name: [profile?.first_name, profile?.last_name].filter(Boolean).join(" ") || null,
      };
    }),
    integrations: integrationsResult.data ?? [],
    calls: callsResult.data ?? [],
    callCount: callCountResult.count ?? 0,
    tickets: ticketsResult.data ?? [],
    activity: logs.map((l) => ({ ...l, actor: emails[l.user_id] ?? null })),
  };
}

async function auditLogList(admin: SupabaseClient, fields: Json) {
  const limit = 50;
  let query = admin
    .from("audit_logs")
    .select("id, action, business_id, user_id, entity_type, entity_id, old_data, new_data, ip_address, created_at")
    .order("created_at", { ascending: false })
    .limit(limit + 1);

  const businessId = text(fields.businessId, 64);
  if (businessId) query = query.eq("business_id", requireId(businessId));

  const search = text(fields.search, 60).toLowerCase().replace(/[^a-z0-9_.]/g, "");
  if (search) query = query.ilike("action", `%${search}%`);

  const before = text(fields.before, 40);
  if (before && !Number.isNaN(Date.parse(before))) query = query.lt("created_at", before);

  const { data, error } = await query;
  if (error) throw error;

  const rows = data ?? [];
  const page = rows.slice(0, limit);
  const [actors, names] = await Promise.all([
    resolveUsers(admin, page.map((r) => r.user_id)),
    businessNames(admin, page.map((r) => r.business_id)),
  ]);

  let businesses: { id: string; name: string }[] | undefined;
  if (!before) {
    const { data: list, error: listError } = await admin
      .from("businesses").select("id, name").order("name");
    if (listError) throw listError;
    businesses = list ?? [];
  }

  return {
    logs: page.map((r) => ({
      ...r,
      actor: actors[r.user_id] ?? null,
      business_name: r.business_id ? names[r.business_id] ?? null : null,
    })),
    nextCursor: rows.length > limit ? page[page.length - 1].created_at : null,
    businesses,
  };
}

// ---------------------------------------------------------------------------
// Industry configuration
// ---------------------------------------------------------------------------

const VOICE_KEYS = [
  "greeting", "caller_role", "staff_role", "booking_action", "primary_service",
] as const;

function slugify(value: string) {
  return value
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60) || "item";
}

function uniqueSlug(base: string, used: Set<string>) {
  let slug = base;
  let n = 2;
  while (used.has(slug)) slug = `${base}-${n++}`;
  used.add(slug);
  return slug;
}

async function industriesList(admin: SupabaseClient) {
  const [industriesResult, configsResult, modulesResult, businessesResult] = await Promise.all([
    admin.from("industries").select("id, name, slug, description, is_active, created_at").order("name"),
    admin.from("industry_configurations").select("industry_id, terminology, updated_at"),
    admin.from("industry_modules")
      .select("id, industry_id, name, slug, description, is_active")
      .order("name"),
    admin.from("businesses").select("industry_id"),
  ]);

  const queryError = industriesResult.error ?? configsResult.error ??
    modulesResult.error ?? businessesResult.error;
  if (queryError) throw queryError;

  const counts = new Map<string, number>();
  for (const b of businessesResult.data ?? []) {
    if (b.industry_id) counts.set(b.industry_id, (counts.get(b.industry_id) ?? 0) + 1);
  }

  const configByIndustry = new Map((configsResult.data ?? []).map((c) => [c.industry_id, c]));
  const modules = modulesResult.data ?? [];

  return {
    industries: (industriesResult.data ?? []).map((industry) => ({
      ...industry,
      terminology: obj(configByIndustry.get(industry.id)?.terminology),
      configUpdatedAt: configByIndustry.get(industry.id)?.updated_at ?? null,
      modules: modules.filter((m) => m.industry_id === industry.id),
      businessCount: counts.get(industry.id) ?? 0,
    })),
  };
}

async function industrySave(admin: SupabaseClient, fields: Json) {
  const industryId = requireId(fields.industryId, "industry");

  const { data: industry, error: industryError } = await admin
    .from("industries").select("id, name").eq("id", industryId).maybeSingle();
  if (industryError) throw industryError;
  if (!industry) throw new InputError("Industry not found", 404);

  const { data: config, error: configError } = await admin
    .from("industry_configurations")
    .select("id, terminology")
    .eq("industry_id", industryId)
    .maybeSingle();
  if (configError) throw configError;

  // Merge onto the existing terminology so keys this page doesn't manage are kept.
  const previous = obj(config?.terminology);
  const input = obj(fields.terminology);
  const next: Json = { ...previous };

  for (const key of TERMINOLOGY_KEYS) {
    const value = text(input[key], 60);
    if (value) next[key] = value;
    else delete next[key];
  }

  const voiceInput = obj(input.voice);
  const voice: Json = { ...obj(previous.voice) };
  for (const key of VOICE_KEYS) {
    const value = text(voiceInput[key], key === "greeting" ? 500 : 60);
    if (value) voice[key] = value;
    else delete voice[key];
  }
  next.voice = voice;

  const now = new Date().toISOString();

  const { error: describeError } = await admin
    .from("industries")
    .update({ description: text(fields.description, 500) || null })
    .eq("id", industryId);
  if (describeError) throw describeError;

  const { error: termsError } = config
    ? await admin.from("industry_configurations")
      .update({ terminology: next, updated_at: now })
      .eq("id", config.id)
    : await admin.from("industry_configurations")
      .insert({ industry_id: industryId, terminology: next });
  if (termsError) throw termsError;

  // Modules are added, renamed or switched off. Never deleted: deleting would
  // silently remove the module from every business that already uses it.
  const { data: current, error: currentError } = await admin
    .from("industry_modules").select("id, slug").eq("industry_id", industryId);
  if (currentError) throw currentError;

  const known = new Set<string>((current ?? []).map((m: { id: string }) => m.id));
  const usedSlugs = new Set<string>((current ?? []).map((m: { slug: string }) => m.slug));
  let created = 0;
  let changed = 0;

  for (const item of list(fields.modules, 60).map(obj)) {
    const name = text(item.name, 80);
    if (!name) throw new InputError("Every module needs a name");

    const values = {
      name,
      description: text(item.description, 300) || null,
      is_active: bool(item.isActive, true),
    };
    const id = text(item.id, 64);

    if (id) {
      if (!known.has(id)) throw new InputError("One of the modules no longer exists. Reload and try again.");
      const { error } = await admin.from("industry_modules")
        .update(values).eq("id", id).eq("industry_id", industryId);
      if (error) throw error;
      changed++;
    } else {
      const { error } = await admin.from("industry_modules").insert({
        ...values,
        industry_id: industryId,
        slug: uniqueSlug(slugify(name), usedSlugs),
      });
      if (error) throw error;
      created++;
    }
  }

  return {
    industryId,
    name: industry.name,
    modulesCreated: created,
    modulesUpdated: changed,
    previousTerminology: previous,
    terminology: next,
  };
}

async function industryCreate(admin: SupabaseClient, fields: Json) {
  const name = text(fields.name, 80);
  if (!name) throw new InputError("Enter an industry name");

  const { data: all, error: allError } = await admin.from("industries").select("name, slug");
  if (allError) throw allError;

  if ((all ?? []).some((i) => i.name.trim().toLowerCase() === name.toLowerCase())) {
    throw new InputError("An industry with this name already exists", 409);
  }

  let terminology: Json = {};
  let modules: { name: string; slug: string; description: string | null }[] = [];
  const copyFromId = text(fields.copyFromId, 64);

  if (copyFromId) {
    requireId(copyFromId, "industry to copy from");
    const [configResult, modulesResult] = await Promise.all([
      admin.from("industry_configurations").select("terminology").eq("industry_id", copyFromId).maybeSingle(),
      admin.from("industry_modules").select("name, slug, description")
        .eq("industry_id", copyFromId).eq("is_active", true),
    ]);
    const copyError = configResult.error ?? modulesResult.error;
    if (copyError) throw copyError;
    terminology = obj(configResult.data?.terminology);
    modules = modulesResult.data ?? [];
  }

  const slug = uniqueSlug(
    slugify(name),
    new Set<string>((all ?? []).map((i: { slug: string }) => i.slug)),
  );

  const { data: industry, error: createError } = await admin
    .from("industries")
    .insert({ name, slug, description: text(fields.description, 500) || null, is_active: true })
    .select("id")
    .single();
  if (createError) throw createError;

  // If anything after this fails, remove the half-created industry.
  try {
    const { error: configError } = await admin
      .from("industry_configurations")
      .insert({ industry_id: industry.id, terminology });
    if (configError) throw configError;

    if (modules.length) {
      const { error: modulesError } = await admin.from("industry_modules").insert(
        modules.map((m) => ({
          industry_id: industry.id,
          name: m.name,
          slug: m.slug,
          description: m.description,
          is_active: true,
        })),
      );
      if (modulesError) throw modulesError;
    }
  } catch (error) {
    await admin.from("industry_modules").delete().eq("industry_id", industry.id);
    await admin.from("industry_configurations").delete().eq("industry_id", industry.id);
    await admin.from("industries").delete().eq("id", industry.id);
    throw error;
  }

  return { industryId: industry.id, name, copiedFrom: copyFromId || null, modules: modules.length };
}

// ---------------------------------------------------------------------------
// AI agents across all businesses
// ---------------------------------------------------------------------------

async function agentsList(admin: SupabaseClient) {
  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();

  const [agentsResult, configsResult, businessesResult, industriesResult, integrationsResult, callsResult] =
    await Promise.all([
      admin.from("ai_agents")
        .select("id, business_id, name, status, updated_at")
        .eq("agent_type", "receptionist"),
      admin.from("ai_agent_configs").select("agent_id, personality, knowledge_base, voice_config, updated_at"),
      admin.from("businesses").select("id, name, industry_id, onboarding_status, is_active"),
      admin.from("industries").select("id, name"),
      admin.from("integrations").select("business_id, provider, status"),
      admin.from("calls")
        .select("business_id, created_at, ai_handled")
        .gte("created_at", since)
        .order("created_at", { ascending: false })
        .limit(10000),
    ]);

  const queryError = agentsResult.error ?? configsResult.error ?? businessesResult.error ??
    industriesResult.error ?? integrationsResult.error ?? callsResult.error;
  if (queryError) throw queryError;

  const configByAgent = new Map((configsResult.data ?? []).map((c) => [c.agent_id, c]));
  const businessById = new Map((businessesResult.data ?? []).map((b) => [b.id, b]));
  const industryName = new Map((industriesResult.data ?? []).map((i) => [i.id, i.name]));

  const connected = (businessId: string, provider: string) =>
    (integrationsResult.data ?? []).some(
      (i) => i.business_id === businessId && i.provider?.toLowerCase() === provider && i.status === "active",
    );

  const callStats = new Map<string, { aiCalls: number; lastCallAt: string | null }>();
  for (const call of callsResult.data ?? []) {
    const stat = callStats.get(call.business_id) ?? { aiCalls: 0, lastCallAt: null };
    if (call.ai_handled) stat.aiCalls++;
    if (!stat.lastCallAt) stat.lastCallAt = call.created_at;
    callStats.set(call.business_id, stat);
  }

  const agents = (agentsResult.data ?? [])
    .filter((agent) => businessById.has(agent.business_id))
    .map((agent) => {
      const business = businessById.get(agent.business_id)!;
      const config = configByAgent.get(agent.id);
      const kb = obj(config?.knowledge_base);
      const hours = obj(kb.hours);
      const services = Array.isArray(kb.services) ? kb.services.length : 0;
      const faqs = Array.isArray(kb.faqs) ? kb.faqs.length : 0;
      const greeting = text(obj(config?.voice_config).greeting, 500);
      const stat = callStats.get(agent.business_id);

      const checks = {
        knowledge: services + faqs > 0,
        hours: Object.values(hours).some((h) => obj(h).closed === true || Boolean(obj(h).open)),
        greeting: Boolean(greeting),
        phone: connected(agent.business_id, "telnyx"),
        voice: connected(agent.business_id, "vapi"),
      };

      return {
        agentId: agent.id,
        businessId: agent.business_id,
        businessName: business.name,
        industry: industryName.get(business.industry_id) ?? "Unassigned",
        stage: business.onboarding_status,
        name: agent.name,
        status: agent.status,
        personality: config?.personality ?? "",
        services,
        faqs,
        checks,
        ready: Object.values(checks).filter(Boolean).length,
        aiCallsLast30Days: stat?.aiCalls ?? 0,
        lastCallAt: stat?.lastCallAt ?? null,
        updatedAt: config?.updated_at ?? agent.updated_at,
      };
    })
    .sort((a, b) => a.businessName.localeCompare(b.businessName));

  return {
    agents,
    stats: {
      total: agents.length,
      live: agents.filter((a) => a.status === "active").length,
      readyToConnect: agents.filter((a) => a.checks.knowledge && a.checks.hours && a.checks.greeting && !a.checks.phone).length,
      missingKnowledge: agents.filter((a) => !a.checks.knowledge).length,
    },
  };
}

// ---------------------------------------------------------------------------
// Platform admins (Users & Access)
// ---------------------------------------------------------------------------

const ADMIN_ROLES = ["super_admin", "zella_owner"] as const;

async function callerRole(admin: SupabaseClient, userId: string) {
  const { data, error } = await admin
    .from("platform_admins")
    .select("role, is_active")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  return data?.is_active ? (data.role as string) : null;
}

async function requireOwner(admin: SupabaseClient, userId: string) {
  if ((await callerRole(admin, userId)) !== "zella_owner") {
    throw new InputError("Only a Zella owner can manage platform admins", 403);
  }
}

async function findUserByEmail(admin: SupabaseClient, email: string) {
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw error;
    const users = data?.users ?? [];
    const match = users.find((u: { email?: string }) => u.email?.toLowerCase() === email);
    if (match) return match;
    if (users.length < 1000) return null;
  }
  return null;
}

async function adminsList(admin: SupabaseClient, userId: string) {
  const { data, error } = await admin
    .from("platform_admins")
    .select("user_id, role, is_active, created_by, created_at")
    .order("created_at", { ascending: true });
  if (error) throw error;

  const rows = data ?? [];
  const emails = await resolveUsers(admin, rows.flatMap((r) => [r.user_id, r.created_by]));

  const lastSignIn: Record<string, string | null> = {};
  await Promise.all(rows.map(async (r) => {
    const { data: u } = await admin.auth.admin.getUserById(r.user_id);
    lastSignIn[r.user_id] = u?.user?.last_sign_in_at ?? null;
  }));

  return {
    me: { userId, role: await callerRole(admin, userId) },
    admins: rows.map((r) => ({
      ...r,
      email: emails[r.user_id] ?? null,
      added_by: r.created_by ? emails[r.created_by] ?? null : null,
      last_sign_in_at: lastSignIn[r.user_id],
      isYou: r.user_id === userId,
    })),
  };
}

async function adminInvite(admin: SupabaseClient, fields: Json, userId: string) {
  await requireOwner(admin, userId);

  const email = text(fields.email, 254).toLowerCase();
  if (!EMAIL_RE.test(email)) throw new InputError("Enter a valid email address");
  const role = oneOf(fields.role, ADMIN_ROLES, "super_admin");

  let target = await findUserByEmail(admin, email);
  let invited = false;

  if (!target) {
    const appUrl = Deno.env.get("ZELLA_APP_URL");
    const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { platform_admin: true },
      ...(appUrl ? { redirectTo: appUrl } : {}),
    });
    if (error || !data?.user) {
      throw new InputError(error?.message ?? "The invitation email could not be sent", 502);
    }
    target = data.user;
    invited = true;
  }

  const { data: existing, error: existingError } = await admin
    .from("platform_admins")
    .select("user_id, is_active")
    .eq("user_id", target.id)
    .maybeSingle();
  if (existingError) throw existingError;

  if (existing?.is_active) throw new InputError("This person is already a platform admin", 409);

  const { error } = existing
    ? await admin.from("platform_admins").update({ is_active: true, role }).eq("user_id", target.id)
    : await admin.from("platform_admins").insert({
      user_id: target.id,
      role,
      is_active: true,
      created_by: userId,
    });
  if (error) throw error;

  return { targetUserId: target.id, email, role, invited, reactivated: Boolean(existing) };
}

async function adminUpdate(admin: SupabaseClient, fields: Json, userId: string) {
  await requireOwner(admin, userId);

  const targetId = requireId(fields.userId, "admin");
  if (targetId === userId) {
    throw new InputError("You can't change your own access. Ask another Zella owner.", 409);
  }

  const { data: current, error: currentError } = await admin
    .from("platform_admins")
    .select("role, is_active")
    .eq("user_id", targetId)
    .maybeSingle();
  if (currentError) throw currentError;
  if (!current) throw new InputError("Admin not found", 404);

  const role = fields.role === undefined ? current.role : oneOf(fields.role, ADMIN_ROLES, current.role);
  const isActive = typeof fields.isActive === "boolean" ? fields.isActive : current.is_active;

  const losingOwner = current.role === "zella_owner" && current.is_active &&
    (role !== "zella_owner" || !isActive);

  if (losingOwner) {
    const { count, error } = await admin
      .from("platform_admins")
      .select("user_id", { count: "exact", head: true })
      .eq("role", "zella_owner")
      .eq("is_active", true);
    if (error) throw error;
    if ((count ?? 0) <= 1) throw new InputError("Zella must keep at least one active owner", 409);
  }

  const { error } = await admin
    .from("platform_admins")
    .update({ role, is_active: isActive })
    .eq("user_id", targetId);
  if (error) throw error;

  return {
    targetUserId: targetId,
    before: { role: current.role, is_active: current.is_active },
    after: { role, is_active: isActive },
  };
}

// ---------------------------------------------------------------------------
// Integrations across businesses
// ---------------------------------------------------------------------------

async function integrationsOverview(admin: SupabaseClient) {
  const [integrationsResult, businessesResult] = await Promise.all([
    admin.from("integrations")
      .select("id, business_id, provider, integration_type, status, account_email, error_message, last_synced_at, updated_at")
      .order("updated_at", { ascending: false }),
    admin.from("businesses").select("id, name, onboarding_status, setup_data").order("name"),
  ]);
  const queryError = integrationsResult.error ?? businessesResult.error;
  if (queryError) throw queryError;

  const integrations = integrationsResult.data ?? [];
  const businesses = businessesResult.data ?? [];
  const nameById = new Map(businesses.map((b) => [b.id, b.name]));

  const hasActive = (businessId: string, provider: string) =>
    integrations.some((i) =>
      i.business_id === businessId && i.provider?.toLowerCase() === provider && i.status === "active"
    );

  // Compare what each client asked for in setup with what's actually connected.
  const requests = businesses.map((b) => {
    const choices = obj(obj(b.setup_data).integrations);
    const phone = obj(choices.phone);
    const leads = obj(choices.lead_sources);
    return {
      businessId: b.id,
      businessName: b.name,
      stage: b.onboarding_status,
      setupDone: Boolean(choices.phone),
      phone: { wanted: phone.mode ? String(phone.mode) : null, connected: hasActive(b.id, "telnyx") },
      voice: { wanted: Boolean(choices.phone), connected: hasActive(b.id, "vapi") },
      calendar: {
        wanted: choices.calendar && choices.calendar !== "none" ? String(choices.calendar) : null,
        connected: hasActive(b.id, String(choices.calendar ?? "")) ||
          hasActive(b.id, choices.calendar === "google" ? "google_calendar" : "outlook_calendar"),
      },
      leads: {
        wanted: Object.entries(leads).filter(([, on]) => on === true).map(([k]) => k),
        connected: ["meta", "website", "google"].filter((k) => hasActive(b.id, k)),
      },
    };
  });

  const byProvider = new Map<string, { provider: string; active: number; problems: number }>();
  for (const i of integrations) {
    const key = i.provider?.toLowerCase() || "unknown";
    const row = byProvider.get(key) ?? { provider: i.provider || "Unknown", active: 0, problems: 0 };
    if (i.status === "active") row.active++;
    if (i.status === "error" || i.status === "disconnected") row.problems++;
    byProvider.set(key, row);
  }

  return {
    connections: integrations.map((i) => ({ ...i, business_name: nameById.get(i.business_id) ?? "Unknown business" })),
    providers: [...byProvider.values()],
    requests,
  };
}

// ---------------------------------------------------------------------------
// Support tickets
// ---------------------------------------------------------------------------

const TICKET_STATUSES = ["open", "in_progress", "resolved", "closed"] as const;
const TICKET_PRIORITIES = ["low", "normal", "high", "urgent"] as const;

async function ticketsList(admin: SupabaseClient) {
  const [ticketsResult, businessesResult, adminsResult] = await Promise.all([
    admin.from("support_tickets")
      .select("id, business_id, subject, description, category, priority, status, assigned_to, created_by, metadata, created_at, updated_at, resolved_at")
      .order("created_at", { ascending: false })
      .limit(500),
    admin.from("businesses").select("id, name").order("name"),
    admin.from("platform_admins").select("user_id").eq("is_active", true),
  ]);
  const queryError = ticketsResult.error ?? businessesResult.error ?? adminsResult.error;
  if (queryError) throw queryError;

  const tickets = ticketsResult.data ?? [];
  const adminIds = (adminsResult.data ?? []).map((a) => a.user_id);
  const noteAuthors = tickets.flatMap((t) =>
    list(obj(t.metadata).notes, 200).map((n) => text(obj(n).author_id, 64))
  );
  const emails = await resolveUsers(admin, [
    ...adminIds,
    ...tickets.flatMap((t) => [t.assigned_to, t.created_by]),
    ...noteAuthors,
  ]);
  const nameById = new Map((businessesResult.data ?? []).map((b) => [b.id, b.name]));

  return {
    tickets: tickets.map((t) => ({
      ...t,
      business_name: nameById.get(t.business_id) ?? "Unknown business",
      assignee: t.assigned_to ? emails[t.assigned_to] ?? null : null,
      creator: t.created_by ? emails[t.created_by] ?? null : null,
      notes: list(obj(t.metadata).notes, 200).map((n) => {
        const note = obj(n);
        return {
          text: text(note.text, 4000),
          created_at: text(note.created_at, 40),
          author: emails[text(note.author_id, 64)] ?? null,
        };
      }),
    })),
    businesses: businessesResult.data ?? [],
    assignees: adminIds.map((id) => ({ id, email: emails[id] ?? id })),
  };
}

async function ticketCreate(admin: SupabaseClient, fields: Json, userId: string) {
  const businessId = requireId(fields.businessId);
  const subject = text(fields.subject, 200);
  if (!subject) throw new InputError("Enter a subject");
  await getBusiness(admin, businessId);

  const { data, error } = await admin
    .from("support_tickets")
    .insert({
      business_id: businessId,
      subject,
      description: text(fields.description, 5000) || null,
      category: text(fields.category, 60) || null,
      priority: oneOf(fields.priority, TICKET_PRIORITIES, "normal"),
      status: "open",
      created_by: userId,
    })
    .select("id")
    .single();
  if (error) throw error;

  return { ticketId: data.id, businessId, subject };
}

async function ticketUpdate(admin: SupabaseClient, fields: Json, userId: string) {
  const ticketId = requireId(fields.ticketId, "ticket");

  const { data: ticket, error: ticketError } = await admin
    .from("support_tickets")
    .select("id, business_id, status, priority, assigned_to, metadata")
    .eq("id", ticketId)
    .maybeSingle();
  if (ticketError) throw ticketError;
  if (!ticket) throw new InputError("Ticket not found", 404);

  const now = new Date().toISOString();
  const update: Json = { updated_at: now };
  const changes: Json = {};

  if (fields.status !== undefined) {
    const status = oneOf(fields.status, TICKET_STATUSES, ticket.status);
    if (status !== ticket.status) {
      update.status = status;
      update.resolved_at = ["resolved", "closed"].includes(status) ? now : null;
      changes.status = { from: ticket.status, to: status };
    }
  }

  if (fields.priority !== undefined) {
    const priority = oneOf(fields.priority, TICKET_PRIORITIES, ticket.priority);
    if (priority !== ticket.priority) {
      update.priority = priority;
      changes.priority = { from: ticket.priority, to: priority };
    }
  }

  if (fields.assignedTo !== undefined) {
    const assignee = text(fields.assignedTo, 64) || null;
    if (assignee) {
      requireId(assignee, "assignee");
      const { data: isAdmin, error } = await admin
        .from("platform_admins").select("user_id").eq("user_id", assignee).eq("is_active", true).maybeSingle();
      if (error) throw error;
      if (!isAdmin) throw new InputError("Tickets can only be assigned to active platform admins");
    }
    if (assignee !== ticket.assigned_to) {
      update.assigned_to = assignee;
      changes.assigned_to = { from: ticket.assigned_to, to: assignee };
    }
  }

  const note = text(fields.note, 4000);
  if (note) {
    const metadata = obj(ticket.metadata);
    update.metadata = {
      ...metadata,
      notes: [...list(metadata.notes, 199), { text: note, author_id: userId, created_at: now }],
    };
    changes.note_added = true;
  }

  if (Object.keys(changes).length === 0) return { ticketId, businessId: ticket.business_id, changes };

  const { error } = await admin.from("support_tickets").update(update).eq("id", ticketId);
  if (error) throw error;

  return { ticketId, businessId: ticket.business_id, changes };
}

// ---------------------------------------------------------------------------
// Plans & subscriptions. Prices are never sent to the browser: pricing
// has not been decided, and plan configuration must not show amounts.
// ---------------------------------------------------------------------------

function withoutPricing(row: Json) {
  return Object.fromEntries(
    Object.entries(row).filter(([key]) => !/price|amount|fee|cost/i.test(key)),
  );
}

async function plansList(admin: SupabaseClient) {
  const [plansResult, subscriptionsResult, businessesResult] = await Promise.all([
    admin.from("plans")
      .select("id, name, slug, description, is_active, features, limits, created_at, updated_at")
      .order("created_at", { ascending: true }),
    admin.from("subscriptions").select("*"),
    admin.from("businesses").select("id, name"),
  ]);
  const queryError = plansResult.error ?? subscriptionsResult.error ?? businessesResult.error;
  if (queryError) throw queryError;

  const plans = plansResult.data ?? [];
  const planName = new Map(plans.map((p) => [p.id, p.name]));
  const businessName = new Map((businessesResult.data ?? []).map((b) => [b.id, b.name]));
  const subscriptions = subscriptionsResult.data ?? [];

  return {
    plans: plans.map((p) => ({
      ...p,
      subscriptions: subscriptions.filter((s) => s.plan_id === p.id).length,
    })),
    subscriptions: subscriptions.map((s) => ({
      ...withoutPricing(s),
      business_name: businessName.get(s.business_id) ?? "Unknown business",
      plan_name: planName.get(s.plan_id) ?? "Unknown plan",
    })),
  };
}

async function planSave(admin: SupabaseClient, fields: Json) {
  const name = text(fields.name, 80);
  if (!name) throw new InputError("Enter a plan name");
  const values = {
    name,
    description: text(fields.description, 500) || null,
    is_active: bool(fields.isActive, true),
    updated_at: new Date().toISOString(),
  };

  const id = text(fields.planId, 64);
  if (id) {
    requireId(id, "plan");
    const { data: before, error: beforeError } = await admin
      .from("plans").select("name, description, is_active").eq("id", id).maybeSingle();
    if (beforeError) throw beforeError;
    if (!before) throw new InputError("Plan not found", 404);

    const { error } = await admin.from("plans").update(values).eq("id", id);
    if (error) throw error;
    return { planId: id, created: false, before, after: { name, description: values.description, is_active: values.is_active } };
  }

  const { data: existing, error: existingError } = await admin.from("plans").select("name, slug");
  if (existingError) throw existingError;
  if ((existing ?? []).some((p) => p.name.trim().toLowerCase() === name.toLowerCase())) {
    throw new InputError("A plan with this name already exists", 409);
  }

  // Price columns are left at their database defaults until pricing is decided.
  const { data, error } = await admin
    .from("plans")
    .insert({
      ...values,
      slug: uniqueSlug(slugify(name), new Set<string>((existing ?? []).map((p: { slug: string }) => p.slug))),
    })
    .select("id")
    .single();
  if (error) throw error;

  return { planId: data.id, created: true, before: null, after: { name, description: values.description, is_active: values.is_active } };
}

// ---------------------------------------------------------------------------
// Platform operations & settings
// ---------------------------------------------------------------------------

async function platformStatus(admin: SupabaseClient, userId: string) {
  const dayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const head = { count: "exact" as const, head: true };

  const checks = await Promise.all([
    admin.from("businesses").select("id", head),
    admin.from("businesses").select("id", head).eq("onboarding_status", "failed"),
    admin.from("business_invitations").select("id", head).eq("status", "failed"),
    admin.from("integrations").select("id", head).in("status", ["error", "disconnected"]),
    admin.from("support_tickets").select("id", head).eq("priority", "urgent").in("status", ["open", "in_progress"]),
    admin.from("audit_logs").select("id", head).gte("created_at", dayAgo),
    admin.from("calls").select("id", head).gte("created_at", dayAgo),
    admin.from("industries").select("id", head).eq("is_active", true),
  ]);

  const failed = checks.find((c) => c.error);
  if (failed?.error) throw failed.error;
  const [businesses, failedSetups, failedInvites, brokenIntegrations, urgentTickets, auditDay, callsDay, industries] =
    checks.map((c) => c.count ?? 0);

  const { data: me } = await admin.auth.admin.getUserById(userId);
  const has = (name: string) => Boolean(Deno.env.get(name));

  return {
    me: {
      email: me?.user?.email ?? null,
      role: await callerRole(admin, userId),
      lastSignInAt: me?.user?.last_sign_in_at ?? null,
    },
    // Only whether each value is set. Secret values never leave the server.
    configuration: [
      { key: "ZELLA_APP_URL", label: "App URL for invitation links", set: has("ZELLA_APP_URL"), required: true },
      { key: "TELNYX_API_KEY", label: "Telnyx (phone numbers)", set: has("TELNYX_API_KEY"), required: false },
      { key: "VAPI_API_KEY", label: "Vapi (voice agents)", set: has("VAPI_API_KEY"), required: false },
      { key: "N8N_WEBHOOK_URL", label: "n8n (automations and emails)", set: has("N8N_WEBHOOK_URL"), required: false },
      { key: "ZELLA_LINK_SECRET", label: "Signing key for \"continue my plan\" links", set: has("ZELLA_LINK_SECRET"), required: false },
    ],
    appUrl: Deno.env.get("ZELLA_APP_URL") ?? null,
    health: {
      businesses, failedSetups, failedInvites, brokenIntegrations, urgentTickets,
      auditLast24h: auditDay, callsLast24h: callsDay, activeIndustries: industries,
    },
    checkedAt: new Date().toISOString(),
  };
}

// ---------------------------------------------------------------------------
// Modules across industries
// ---------------------------------------------------------------------------

async function modulesOverview(admin: SupabaseClient) {
  const [modulesResult, industriesResult, enabledResult] = await Promise.all([
    admin.from("industry_modules").select("id, industry_id, name, slug, description, is_active"),
    admin.from("industries").select("id, name, is_active"),
    admin.from("business_modules").select("module_id, business_id").eq("enabled", true),
  ]);
  const queryError = modulesResult.error ?? industriesResult.error ?? enabledResult.error;
  if (queryError) throw queryError;

  const industryName = new Map((industriesResult.data ?? []).map((i) => [i.id, i.name]));
  const businessesByModule = new Map<string, Set<string>>();
  for (const row of enabledResult.data ?? []) {
    const set = businessesByModule.get(row.module_id) ?? new Set<string>();
    set.add(row.business_id);
    businessesByModule.set(row.module_id, set);
  }

  // Group the same module (by slug) across industries.
  const groups = new Map<string, {
    slug: string; name: string; description: string | null;
    offeredIn: string[]; hiddenIn: string[]; businesses: Set<string>;
  }>();
  for (const m of modulesResult.data ?? []) {
    const group = groups.get(m.slug) ?? {
      slug: m.slug, name: m.name, description: m.description,
      offeredIn: [], hiddenIn: [], businesses: new Set<string>(),
    };
    const industry = String(industryName.get(m.industry_id) ?? "Unknown industry");
    (m.is_active ? group.offeredIn : group.hiddenIn).push(industry);
    if (!group.description && m.description) group.description = m.description;
    for (const b of businessesByModule.get(m.id) ?? []) group.businesses.add(b);
    groups.set(m.slug, group);
  }

  return {
    modules: [...groups.values()]
      .map((g) => ({
        slug: g.slug,
        name: g.name,
        description: g.description,
        offeredIn: g.offeredIn.sort(),
        hiddenIn: g.hiddenIn.sort(),
        businesses: g.businesses.size,
        requires: MODULE_DEPENDENCIES[g.slug] ?? [],
      }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    industries: (industriesResult.data ?? []).filter((i) => i.is_active).length,
  };
}

// ---------------------------------------------------------------------------
// Business lifecycle: suspend, reactivate, cancel at month end
// ---------------------------------------------------------------------------

const LIFECYCLE_ERRORS: Record<string, [string, number]> = {
  BUSINESS_NOT_FOUND: ["Business not found", 404],
  BUSINESS_CANCELLED: ["This business has been cancelled", 409],
  ALREADY_SUSPENDED: ["This business is already suspended", 409],
  NOT_SUSPENDED: ["This business isn't suspended", 409],
};

function lifecycleError(error: { message?: string }) {
  for (const [code, [message, status]] of Object.entries(LIFECYCLE_ERRORS)) {
    if (error.message?.includes(code)) return new InputError(message, status);
  }
  return error;
}

// Carries out cancellations whose date has passed. Never blocks the page.
async function processCancellations(admin: SupabaseClient) {
  const { error } = await admin.rpc("zella_process_cancellations");
  if (error) console.error("Cancellation processing failed", error);
}

// The same day next month as the anchor (clamped to short months),
// i.e. when the business's current month is over.
function nextMonthlyBoundary(anchorIso: string, now = new Date()) {
  const anchor = new Date(anchorIso);
  const day = anchor.getUTCDate();
  const build = (year: number, month: number) => {
    const lastDay = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
    return new Date(Date.UTC(year, month, Math.min(day, lastDay), anchor.getUTCHours(), anchor.getUTCMinutes()));
  };
  let year = now.getUTCFullYear();
  let month = now.getUTCMonth();
  let candidate = build(year, month);
  if (candidate <= now) {
    month += 1;
    if (month > 11) {
      month = 0;
      year += 1;
    }
    candidate = build(year, month);
  }
  return candidate;
}

// --- Signed "continue my plan" links and n8n events -------------------------

function base64Url(bytes: Uint8Array) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function hmacSign(secret: string, data: string) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return base64Url(new Uint8Array(signature));
}

// The link is only valid for this business and this exact cancellation date.
async function continuePlanUrl(businessId: string, cancelAt: string) {
  const secret = Deno.env.get("ZELLA_LINK_SECRET");
  const appUrl = Deno.env.get("ZELLA_APP_URL");
  if (!secret || !appUrl) return null;
  const payload = base64Url(new TextEncoder().encode(JSON.stringify({ b: businessId, c: cancelAt })));
  const token = `${payload}.${await hmacSign(secret, payload)}`;
  return `${appUrl.replace(/\/+$/, "")}/continue-plan?token=${encodeURIComponent(token)}`;
}

// Sends an event to n8n, which sends the emails. Never throws: a failed email
// must not undo the admin's action, but the result is reported back.
async function sendToN8n(event: string, payload: Json) {
  const url = Deno.env.get("N8N_WEBHOOK_URL");
  if (!url) return { sent: false, reason: "n8n is not connected yet (N8N_WEBHOOK_URL not set)" };

  const secret = Deno.env.get("N8N_WEBHOOK_SECRET");
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(secret ? { Authorization: `Bearer ${secret}` } : {}),
      },
      body: JSON.stringify({ event, sent_at: new Date().toISOString(), ...payload }),
      signal: AbortSignal.timeout(8000),
    });
    return response.ok
      ? { sent: true, reason: null }
      : { sent: false, reason: `n8n responded with ${response.status}` };
  } catch (error) {
    console.error("n8n event failed", event, error);
    return { sent: false, reason: "n8n could not be reached" };
  }
}

async function ownerContact(admin: SupabaseClient, businessId: string) {
  const { data, error } = await admin
    .from("business_invitations")
    .select("email, owner_name, status")
    .eq("business_id", businessId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data ? { email: data.email, name: data.owner_name } : null;
}

async function businessSuspend(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const reason = text(fields.reason, 500);
  const { error } = await admin.rpc("zella_suspend_business", { p_business_id: businessId, p_reason: reason });
  if (error) throw lifecycleError(error);
  return { businessId, reason };
}

async function businessReactivate(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const { error } = await admin.rpc("zella_reactivate_business", { p_business_id: businessId });
  if (error) throw lifecycleError(error);
  return { businessId };
}

async function businessCancel(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const reason = text(fields.reason, 500);
  const business = await getBusiness(admin, businessId);

  if (business.cancelled_at) throw new InputError("This business has already been cancelled", 409);
  if (business.cancel_at) throw new InputError("A cancellation is already scheduled", 409);

  const { data: subscriptions, error: subsError } = await admin
    .from("subscriptions")
    .select("*")
    .eq("business_id", businessId);
  if (subsError) throw subsError;

  const current = (subscriptions ?? []).find((s) =>
    ["trial", "active", "renewal_due", "past_due", "grace_period"].includes(s.status)
  );

  // Prefer the subscription's own period end; otherwise the business's monthly
  // anniversary (from when its subscription, or the business, started).
  const now = new Date();
  const periodEnd = current?.current_period_end ? new Date(current.current_period_end) : null;
  const cancelAt = periodEnd && periodEnd > now
    ? periodEnd
    : nextMonthlyBoundary(current?.current_period_start ?? current?.created_at ?? business.created_at, now);

  const { error } = await admin
    .from("businesses")
    .update({
      cancel_at: cancelAt.toISOString(),
      cancel_requested_at: now.toISOString(),
      cancellation_reason: reason || null,
      updated_at: now.toISOString(),
    })
    .eq("id", businessId);
  if (error) throw error;

  // Email the owner a "continue my plan" link (sent by n8n).
  const owner = await ownerContact(admin, businessId);
  const continueUrl = await continuePlanUrl(businessId, cancelAt.toISOString());
  let email = { sent: false, reason: null as string | null };

  if (!owner) {
    email.reason = "This business has no owner email";
  } else if (!continueUrl) {
    email.reason = "ZELLA_LINK_SECRET or ZELLA_APP_URL is not set";
  } else {
    email = await sendToN8n("business.cancellation_scheduled", {
      business_id: businessId,
      business_name: business.name,
      owner_name: owner.name,
      owner_email: owner.email,
      cancel_at: cancelAt.toISOString(),
      timezone: business.timezone,
      continue_url: continueUrl,
    });
  }

  return {
    businessId,
    cancelAt: cancelAt.toISOString(),
    reason,
    emailSent: email.sent,
    emailError: email.reason,
  };
}

async function businessUndoCancel(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const business = await getBusiness(admin, businessId);
  if (business.cancelled_at) {
    throw new InputError("The cancellation has already taken effect and can't be undone here", 409);
  }
  if (!business.cancel_at) throw new InputError("No cancellation is scheduled", 409);

  const { error } = await admin
    .from("businesses")
    .update({
      cancel_at: null,
      cancel_requested_at: null,
      cancellation_reason: null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", businessId);
  if (error) throw error;

  // Lets n8n stop any reminder emails it has scheduled for this cancellation.
  await sendToN8n("business.cancellation_undone", {
    business_id: businessId,
    business_name: business.name,
    previous_cancel_at: business.cancel_at,
  });

  return { businessId, previousCancelAt: business.cancel_at };
}

async function invitationResend(admin: SupabaseClient, fields: Json) {
  const businessId = requireId(fields.businessId);
  const business = await getBusiness(admin, businessId);
  if (business.cancelled_at) throw new InputError("This business has been cancelled", 409);

  const { data: invitation, error: invitationError } = await admin
    .from("business_invitations")
    .select("id, email, owner_name, status")
    .eq("business_id", businessId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (invitationError) throw invitationError;
  if (!invitation) throw new InputError("This business has no owner invitation yet");
  if (invitation.status === "accepted") throw new InputError("The owner has already accepted the invitation", 409);

  const now = new Date().toISOString();
  const appUrl = Deno.env.get("ZELLA_APP_URL");
  const { data: invited, error } = await admin.auth.admin.inviteUserByEmail(invitation.email, {
    data: { full_name: invitation.owner_name, business_id: businessId },
    ...(appUrl ? { redirectTo: appUrl } : {}),
  });

  if (error || !invited?.user) {
    const reason = error?.message ?? "Invitation email could not be sent";
    await admin.from("business_invitations")
      .update({ status: "failed", last_error: reason, updated_at: now })
      .eq("id", invitation.id);
    return {
      businessId,
      email: invitation.email,
      invitationStatus: "failed",
      invitationError: /already|registered|exists/i.test(reason)
        ? "This email already has a confirmed Zella account. They can sign in with their existing password."
        : reason,
    };
  }

  await admin.from("business_invitations").update({
    status: "sent",
    auth_user_id: invited.user.id,
    invited_at: now,
    expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
    last_error: null,
    updated_at: now,
  }).eq("id", invitation.id);

  const { data: member } = await admin
    .from("business_members")
    .select("id")
    .eq("business_id", businessId)
    .eq("user_id", invited.user.id)
    .maybeSingle();
  if (!member) {
    const { error: memberError } = await admin.from("business_members").insert({
      business_id: businessId,
      user_id: invited.user.id,
      role: "owner",
      status: "invited",
    });
    if (memberError) console.error("Owner membership insert failed", memberError);
  }

  return { businessId, email: invitation.email, invitationStatus: "sent" };
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return respond({ error: "Method not allowed" }, 405);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey =
      Deno.env.get("SUPABASE_ANON_KEY") ??
      Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
    const serverSecretKey = Deno.env.get("ZELLA_SERVER_SECRET_KEY");

    if (!supabaseUrl || !publishableKey || !serverSecretKey) {
      console.error("Required server configuration is missing");
      return respond(
        { error: "Server configuration is incomplete" },
        500,
      );
    }

    const authorization = req.headers.get("Authorization");

    if (!authorization?.startsWith("Bearer ")) {
      return respond({ error: "Please sign in first" }, 401);
    }

    // Verify the caller's own access token.
    const callerClient = createClient(
      supabaseUrl,
      publishableKey,
      {
        global: {
          headers: { Authorization: authorization },
        },
        auth: {
          persistSession: false,
          autoRefreshToken: false,
        },
      },
    );

    const {
      data: { user },
      error: userError,
    } = await callerClient.auth.getUser();

    if (userError || !user) {
      return respond({ error: "Please sign in first" }, 401);
    }

    // Only an active, authorized platform administrator may continue.
    const { data: isAdmin, error: adminError } =
      await callerClient.rpc("is_platform_admin");

    if (adminError) {
      console.error("Platform admin verification failed", adminError);
      return respond(
        { error: "Could not verify platform admin access" },
        500,
      );
    }

    if (isAdmin !== true) {
      return respond(
        { error: "Platform admin access required" },
        403,
      );
    }

    let body: unknown;

    try {
      body = await req.json();
    } catch {
      return respond(
        { error: "Request body must be valid JSON" },
        400,
      );
    }

    if (
      typeof body !== "object" ||
      body === null ||
      Array.isArray(body)
    ) {
      return respond(
        { error: "Request body must be a JSON object" },
        400,
      );
    }

    const fields = body as Json;
    const action =
      typeof fields.action === "string" ? fields.action : "";

    // Server-side client, used only after admin verification.
    const adminClient = createClient(supabaseUrl, serverSecretKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    if (action === "dashboard_data") {
      await processCancellations(adminClient);

      const [
        businessesResult,
        industriesResult,
        invitationsResult,
        subscriptionsResult,
        membersResult,
      ] = await Promise.all([
        adminClient
          .from("businesses")
          .select(
            "id, name, industry_id, phone, timezone, onboarding_status, is_active, created_at, suspended_at, cancel_at, cancelled_at",
          )
          .order("created_at", { ascending: false }),

        adminClient
          .from("industries")
          .select("id, name, slug, is_active")
          .eq("is_active", true)
          .order("name"),

        adminClient
          .from("business_invitations")
          .select(
            "id, business_id, email, owner_name, status, invited_at, expires_at, created_at",
          )
          .order("created_at", { ascending: false }),

        adminClient
          .from("subscriptions")
          .select("id, business_id, status"),

        adminClient
          .from("business_members")
          .select("business_id, user_id, role, status"),
      ]);

      const queryError =
        businessesResult.error ??
        industriesResult.error ??
        invitationsResult.error ??
        subscriptionsResult.error ??
        membersResult.error;

      if (queryError) {
        console.error("Dashboard data query failed", queryError);
        return respond(
          { error: "Unable to load platform dashboard data" },
          500,
        );
      }

      const businesses = businessesResult.data ?? [];
      const industries = industriesResult.data ?? [];
      const invitations = invitationsResult.data ?? [];
      const subscriptions = subscriptionsResult.data ?? [];
      const members = membersResult.data ?? [];

      const industryById = new Map(
        industries.map((industry) => [industry.id, industry.name]),
      );

      const groupBy = <T extends { business_id: string }>(rows: T[]) => {
        const map = new Map<string, T[]>();
        for (const row of rows) {
          const current = map.get(row.business_id) ?? [];
          current.push(row);
          map.set(row.business_id, current);
        }
        return map;
      };

      const invitationsByBusiness = groupBy(invitations);
      const subscriptionsByBusiness = groupBy(subscriptions);
      const membersByBusiness = groupBy(members);

      const businessRecords = businesses.map((business) => ({
        ...business,
        industry_name:
          industryById.get(business.industry_id) ?? "Unassigned",
        invitations: invitationsByBusiness.get(business.id) ?? [],
        subscriptions:
          subscriptionsByBusiness.get(business.id) ?? [],
        members: membersByBusiness.get(business.id) ?? [],
      }));

      return respond({
        businesses: businessRecords,
        industries,
        stats: {
          totalBusinesses: businesses.length,
          activeWorkspaces: businesses.filter(
            (item) => item.is_active,
          ).length,
          pendingInvitations: invitations.filter(
            (item) => item.status === "pending" || item.status === "sent",
          ).length,
          provisioningIssues: invitations.filter(
            (item) => item.status === "failed",
          ).length,
          totalMembers: members.length,
          totalSubscriptions: subscriptions.length,
        },
      });
    }

    const handlers: Record<string, () => Promise<unknown>> = {
      setup_load: () => loadSetup(adminClient, requireId(fields.businessId)),
      setup_save_business: () => saveBusiness(adminClient, fields),
      setup_save_owner: () => saveOwner(adminClient, fields, user.id),
      setup_save_terminology: () => saveTerminology(adminClient, fields),
      setup_save_modules: () => saveModules(adminClient, fields),
      setup_save_receptionist: () => saveReceptionist(adminClient, fields),
      setup_save_integrations: () => saveIntegrations(adminClient, fields),
      setup_save_automations: () => saveAutomations(adminClient, fields, user.id),
      setup_finish: () => finishSetup(adminClient, fields),
      overview_data: () => overviewData(adminClient),
      business_detail: () => businessDetail(adminClient, requireId(fields.businessId)),
      audit_logs: () => auditLogList(adminClient, fields),
      industries_list: () => industriesList(adminClient),
      industry_save: () => industrySave(adminClient, fields),
      industry_create: () => industryCreate(adminClient, fields),
      agents_list: () => agentsList(adminClient),
      admins_list: () => adminsList(adminClient, user.id),
      admin_invite: () => adminInvite(adminClient, fields, user.id),
      admin_update: () => adminUpdate(adminClient, fields, user.id),
      integrations_overview: () => integrationsOverview(adminClient),
      tickets_list: () => ticketsList(adminClient),
      ticket_create: () => ticketCreate(adminClient, fields, user.id),
      ticket_update: () => ticketUpdate(adminClient, fields, user.id),
      plans_list: () => plansList(adminClient),
      plan_save: () => planSave(adminClient, fields),
      platform_status: () => platformStatus(adminClient, user.id),
      business_suspend: () => businessSuspend(adminClient, fields),
      business_reactivate: () => businessReactivate(adminClient, fields),
      business_cancel: () => businessCancel(adminClient, fields),
      business_undo_cancel: () => businessUndoCancel(adminClient, fields),
      invitation_resend: () => invitationResend(adminClient, fields),
      modules_overview: () => modulesOverview(adminClient),
    };

    const handler = handlers[action];
    if (!handler) return respond({ error: "Unknown action" }, 400);

    try {
      const result = await handler();

      const describe = AUDITED[action];
      const unchanged = action === "ticket_update" &&
        Object.keys(obj((result as Json).changes)).length === 0;
      if (describe && !unchanged) {
        await writeAudit(adminClient, requestContext(req, user.id), describe(fields, result));
      }

      return respond(result);
    } catch (error) {
      if (error instanceof InputError) {
        return respond({ error: error.message }, error.status);
      }
      console.error(`Setup action ${action} failed`, error);
      return respond({ error: "The change could not be saved. Please try again." }, 500);
    }
  } catch (error) {
    console.error("Platform dashboard function failed", error);
    return respond({ error: "Unexpected server error" }, 500);
  }
});
