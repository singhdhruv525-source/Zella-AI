// Shared helpers for a business workspace: its words and receptionist status.

const FALLBACK_TERMS = {
  customer: "Customer", customers: "Customers", appointment: "Appointment",
  appointments: "Appointments", staff: "Staff member", staff_plural: "Staff",
  service: "Service", services: "Services", job: "Job", jobs: "Jobs",
};

// term("customers") → "Patients" for a dental clinic, "Customers" for a plumber.
export function makeTerm(workspace) {
  return (key) => workspace?.terminology?.[key] || FALLBACK_TERMS[key] || key;
}

export function receptionistState(workspace) {
  const status = workspace.receptionist?.status;
  if (status === "active" && workspace.phone_connected) return { label: "Online", tone: "success", live: true };
  if (status === "paused") return { label: "Paused", tone: "warning", live: false };
  return { label: "Not live yet", tone: "", live: false };
}
