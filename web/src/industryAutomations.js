// Which automations make sense for each kind of business, picked the moment an
// industry is chosen. The admin can still change any of them.
// Every value here is one the server accepts (see owner-provision-business).

const BASE = {
  appointment_reminder: { enabled: true, settings: { hours_before: [24, 2], channel: "sms" } },
  appointment_confirmation: { enabled: true, settings: { hours_before: 24, channel: "sms" } },
  no_show_follow_up: { enabled: true, settings: { minutes_after: 15, channel: "call" } },
  missed_call_follow_up: { enabled: true, settings: { minutes_after: 5, max_attempts: 2, fallback_sms: true } },
  new_lead_callback: { enabled: true, settings: { minutes_after: 5, max_attempts: 2, retry_after_hours: 24, fallback_sms: true, contact_within_minutes: 15, escalate_after_minutes: 60 } },
  post_appointment_follow_up: { enabled: false, settings: { hours_after: 24, channel: "sms" } },
  quote_follow_up: { enabled: false, settings: { hours_after: 48, max_attempts: 2, channel: "sms" } },
  lead_reactivation: { enabled: false, settings: { days_inactive: 30, channel: "sms" } },
  waitlist_offer: { enabled: false, settings: { offers: 3, offer_minutes: 30, channel: "sms" } },
  staff_unavailable: { enabled: false, settings: { channel: "sms" } },
};

export const emptyAutomations = () => structuredClone(BASE);

function build(changes) {
  const out = structuredClone(BASE);
  for (const [type, change] of Object.entries(changes)) {
    out[type] = { enabled: change.enabled ?? out[type].enabled, settings: { ...out[type].settings, ...(change.settings ?? {}) } };
  }
  return out;
}

const APPOINTMENT_BASED = build({
  post_appointment_follow_up: { enabled: true },
  waitlist_offer: { enabled: true },
  staff_unavailable: { enabled: true },
});

const TRADES = build({
  appointment_reminder: { settings: { hours_before: [24, 2] } },
  no_show_follow_up: { settings: { minutes_after: 30 } },
  missed_call_follow_up: { settings: { minutes_after: 0, max_attempts: 3 } },
  new_lead_callback: { settings: { minutes_after: 0, max_attempts: 3, contact_within_minutes: 5, escalate_after_minutes: 30 } },
  post_appointment_follow_up: { enabled: true },
  quote_follow_up: { enabled: true, settings: { hours_after: 48, max_attempts: 2 } },
  lead_reactivation: { enabled: true, settings: { days_inactive: 90 } },
  staff_unavailable: { enabled: true },
});

const REAL_ESTATE = build({
  missed_call_follow_up: { settings: { minutes_after: 0, max_attempts: 3 } },
  new_lead_callback: { settings: { minutes_after: 0, max_attempts: 3, contact_within_minutes: 5, escalate_after_minutes: 30 } },
  no_show_follow_up: { settings: { minutes_after: 30 } },
  post_appointment_follow_up: { enabled: true, settings: { hours_after: 2 } },
  lead_reactivation: { enabled: true, settings: { days_inactive: 30 } },
  staff_unavailable: { enabled: true },
});

const RESTAURANT = build({
  appointment_reminder: { settings: { hours_before: [2] } },
  no_show_follow_up: { enabled: false },
  missed_call_follow_up: { settings: { max_attempts: 1 } },
  new_lead_callback: { enabled: false },
  quote_follow_up: { enabled: true, settings: { hours_after: 48 } },
  waitlist_offer: { enabled: true, settings: { offers: 3, offer_minutes: 15 } },
});

const TRAVEL_STAY = build({
  appointment_reminder: { settings: { hours_before: [48, 24] } },
  appointment_confirmation: { settings: { hours_before: 48 } },
  no_show_follow_up: { enabled: false },
  new_lead_callback: { settings: { minutes_after: 15 } },
  post_appointment_follow_up: { enabled: true, settings: { channel: "email" } },
  quote_follow_up: { enabled: true, settings: { hours_after: 48, max_attempts: 3 } },
  lead_reactivation: { enabled: true, settings: { days_inactive: 60 } },
});

const ECOMMERCE = build({
  appointment_reminder: { enabled: false },
  appointment_confirmation: { enabled: false },
  no_show_follow_up: { enabled: false },
  new_lead_callback: { enabled: false },
  lead_reactivation: { enabled: true, settings: { days_inactive: 60 } },
});

const BY_NAME = {
  dental: APPOINTMENT_BASED, healthcare: APPOINTMENT_BASED, beautysalon: build({ ...{ post_appointment_follow_up: { enabled: true }, waitlist_offer: { enabled: true }, staff_unavailable: { enabled: true }, lead_reactivation: { enabled: true, settings: { days_inactive: 30 } } } }),
  fitness: build({ post_appointment_follow_up: { enabled: true }, lead_reactivation: { enabled: true, settings: { days_inactive: 30 } }, waitlist_offer: { enabled: true }, staff_unavailable: { enabled: true } }),
  education: build({ post_appointment_follow_up: { enabled: true }, lead_reactivation: { enabled: true, settings: { days_inactive: 60 } }, staff_unavailable: { enabled: true } }),
  legal: build({ post_appointment_follow_up: { enabled: true }, staff_unavailable: { enabled: true } }),
  financialservices: build({ post_appointment_follow_up: { enabled: true }, quote_follow_up: { enabled: true }, staff_unavailable: { enabled: true } }),
  professionalservices: build({ post_appointment_follow_up: { enabled: true }, quote_follow_up: { enabled: true, settings: { hours_after: 72 } }, lead_reactivation: { enabled: true, settings: { days_inactive: 60 } }, staff_unavailable: { enabled: true } }),
  plumbing: TRADES, electrical: TRADES, hvac: TRADES, homeservices: TRADES, automotive: TRADES,
  petcareveterinary: build({ post_appointment_follow_up: { enabled: true }, lead_reactivation: { enabled: true, settings: { days_inactive: 90 } }, staff_unavailable: { enabled: true } }),
  landscapinglawncare: TRADES, pestcontrol: TRADES, cleaningservices: TRADES, propertymanagement: TRADES,
  spawellness: build({ post_appointment_follow_up: { enabled: true }, waitlist_offer: { enabled: true }, staff_unavailable: { enabled: true }, lead_reactivation: { enabled: true, settings: { days_inactive: 45 } } }),
  photographyevents: build({ quote_follow_up: { enabled: true, settings: { hours_after: 72 } }, post_appointment_follow_up: { enabled: true }, staff_unavailable: { enabled: true } }),
  childcare: build({ appointment_reminder: { settings: { hours_before: [24] } }, staff_unavailable: { enabled: true }, lead_reactivation: { enabled: false } }),
  insurance: build({ post_appointment_follow_up: { enabled: true }, quote_follow_up: { enabled: true }, staff_unavailable: { enabled: true } }),
  realestate: REAL_ESTATE, restaurant: RESTAURANT, travel: TRAVEL_STAY, hospitality: TRAVEL_STAY, ecommerce: ECOMMERCE,
};

// industryName: the name as shown in the admin ("Real Estate", "Beauty & Salon", ...).
export function automationDefaultsFor(industryName) {
  const key = String(industryName ?? "").toLowerCase().replace(/[^a-z]/g, "");
  return structuredClone(BY_NAME[key] ?? BASE);
}
