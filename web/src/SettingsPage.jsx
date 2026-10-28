import { useEffect, useState } from "react";
import "./OwnerPages.css";
import { supabase } from "./supabase";
import { callOwnerFunction } from "./CreateBusinessWizard";
import { navigate } from "./router";
import SettingsWorkspace from "./settings/SettingsWorkspace";
import { Icon } from "./BusinessUI";
import { Banner, Loading } from "./settings/SettingsKit";
import { AccountSecurityPanel, MyProfilePanel, SignOutPanel } from "./settings/PersonalPanels";
import { AppearancePanel } from "./settings/AppearancePanel";
import * as P from "./settings/AdminPanels";
import { AdminCallingUsage } from "./settings/CallingUsagePanels";
import { FailedEventsPanel, HealthPanel, IncidentsPanel } from "./PlatformMonitoring";
import { MonitorTab, ReportsTab, RulesTab } from "./OffersPage";

// Admin Settings: one Settings item in the main sidebar opens this workspace,
// with 17 categories and their pages at /settings/<category>/<page>.

// Outline icons (Material Symbols), the same set the sidebars use.
const Glyph = ({ name }) => <span className="zs-glyph"><Icon name={GLYPHS[name] ?? "radio_button_unchecked"} size="sm" /></span>;
const GLYPHS = { search: "search", general: "tune", tenants: "storefront", users: "group", plans: "workspace_premium", offers: "sell", billing: "payments", ai: "smart_toy", voice: "call", comms: "forum", integrations: "hub", security: "shield", alerts: "notifications", support: "support_agent", analytics: "monitoring", legal: "gavel", dev: "code", profile: "person" };

const page = (key, label, render, keywords = "") => ({ key, label, render, keywords });

function registry() {
  return [
    { key: "general", label: "General platform settings", icon: "general", items: [
      page("profile", "Platform profile", (c) => <P.PlatformProfile me={c.me} />, "name legal support email phone website address country timezone currency"),
      page("branding", "Branding and appearance", (c) => <P.Branding me={c.me} />, "logo favicon theme colour color login email"),
      page("localization", "Localization", () => <P.Localization />, "language date time currency format locale"),
      page("maintenance", "Platform maintenance", (c) => <P.Maintenance me={c.me} />, "maintenance announcement downtime read-only"),
      page("operations", "Operational rules", (c) => <P.OperationalRules me={c.me} />, "response time task overdue escalate summary missed call transfer invitation reminder setup incomplete trial notice sample low confidence knowledge threshold"),
    ] },
    { key: "tenants", label: "Business and tenant management", icon: "tenants", items: [
      page("all", "All businesses", (c) => <P.AllBusinesses openBusiness={c.openBusiness} />, "search filter industry plan status onboarding created"),
      page("onboarding", "Business onboarding", (c) => <P.Onboarding me={c.me} openSetup={c.openSetup} openBusiness={c.openBusiness} />, "setup blockers invite"),
      page("lifecycle", "Status and lifecycle", (c) => <P.Lifecycle openBusiness={c.openBusiness} />, "suspend deactivate cancel delete"),
      page("details", "Business details", (c) => <P.BusinessDetailsPicker openBusiness={c.openBusiness} />, "owner members subscription modules"),
      page("provisioning", "Business provisioning", (c) => <P.Provisioning openBusiness={c.openBusiness} />, "workspace errors retry"),
      page("data", "Data lifecycle", (c) => <P.DataLifecycle me={c.me} />, "export deletion retention"),
    ] },
    { key: "users", label: "Users, roles and access", icon: "users", items: [
      page("admins", "Platform administrators", (c) => <P.Administrators onNavigate={c.onNavigate} />, "admin invite mfa last login"),
      page("roles", "Platform roles", (c) => <P.PlatformRoles me={c.me} />, "role matrix super admin billing support security read-only"),
      page("permissions", "Permissions", () => <P.Permissions />, "permission enforcement"),
      page("auth", "Authentication policies", () => <P.AuthPolicies />, "password mfa session providers recovery"),
    ] },
    { key: "plans", label: "Plans, subscriptions and entitlements", icon: "plans", items: [
      page("plans", "Plan management", (c) => <P.PlanManagement me={c.me} onNavigate={c.onNavigate} />, "create edit archive price"),
      page("entitlements", "Plan entitlements", (c) => <P.PlanEntitlements me={c.me} />, "allowance minutes sms seats numbers limits"),
      page("subscriptions", "Subscription management", () => <P.Subscriptions />, "trial past due cancelled renewal"),
      page("promotions", "Trials and promotions", (c) => <P.TrialsPromotions onNavigate={c.onNavigate} onGo={c.onGo} />, "promo code discount trial"),
      page("enforcement", "Entitlement enforcement", () => <P.EntitlementEnforcement />, "limits enforced"),
    ] },
    { key: "offers", label: "Offers and promotions", icon: "offers", items: [
      page("overview", "Offers overview", (c) => <P.OffersGate me={c.me}><P.OffersOverview onNavigate={c.onNavigate} /></P.OffersGate>, "offers promo code discount deal status approval connections"),
      page("rules", "Offer automation rules", (c) => <P.OffersGate me={c.me}><RulesTab onChanged={() => {}} /></P.OffersGate>, "start end approval thresholds claim hold unpaid expiry warning limit unusual activity renewal referral win-back abandoned checkout"),
      page("monitoring", "Offer monitoring", (c) => <P.OffersGate me={c.me}><MonitorTab onOpenOffer={() => c.onNavigate("Offers & Promotions")} /></P.OffersGate>, "claims failed codes attempts activity"),
      page("reports", "Offer reports", (c) => <P.OffersGate me={c.me}><ReportsTab /></P.OffersGate>, "redemptions revenue discount report"),
    ] },
    { key: "billing", label: "Billing and financial operations", icon: "billing", items: [
      page("overview", "Billing overview", () => <P.BillingOverview />, "mrr arr revenue"),
      page("payments", "Payments", () => <P.Payments />, "transactions"),
      page("invoices", "Invoices", () => <P.Invoices />, "invoice tax"),
      page("refunds", "Refunds and adjustments", () => <P.Refunds />, "refund credit"),
      page("calling-usage", "Calling usage", () => <AdminCallingUsage />, "calling minutes usage ledger reconciliation threshold retry discrepancy"),
      page("config", "Billing configuration", (c) => <P.BillingConfig me={c.me} />, "stripe grace retry tax"),
    ] },
    { key: "ai", label: "AI providers and agents", icon: "ai", items: [
      page("providers", "AI provider configuration", (c) => <P.AiProviders me={c.me} />, "model anthropic vapi health"),
      page("registry", "AI agent registry", (c) => <P.AgentRegistry onNavigate={c.onNavigate} />, "agents"),
      page("configuration", "AI agent configuration", (c) => <P.AgentConfiguration onNavigate={c.onNavigate} />, "instructions defaults versions"),
      page("testing", "AI testing and evaluation", () => <P.AiTesting />, "eval test accuracy"),
      page("guardrails", "AI safety and guardrails", () => <P.AiGuardrails />, "safety handoff injection"),
    ] },
    { key: "voice", label: "Voice, telephony and usage", icon: "voice", items: [
      page("providers", "Telephony providers", () => <P.TelephonyProviders />, "telnyx twilio vapi"),
      page("numbers", "Phone number management", (c) => <P.PhoneNumbers me={c.me} />, "assign reassign release"),
      page("usage", "Voice usage", () => <P.VoiceUsage />, "minutes calls cost"),
      page("costs", "Voice cost configuration", (c) => <P.VoiceCosts me={c.me} />, "pricing rate per minute"),
      page("limits", "Usage limits", () => <P.UsageLimits />, "top-up spending limit"),
    ] },
    { key: "comms", label: "SMS, email and communications", icon: "comms", items: [
      page("sms", "SMS configuration", (c) => <P.SmsConfig me={c.me} />, "text telnyx sender opt-out"),
      page("email", "Email configuration", (c) => <P.EmailConfig me={c.me} />, "resend sender bounce"),
      page("templates", "Communication templates", () => <P.Templates />, "template preview variables"),
      page("delivery", "Delivery monitoring", (c) => <P.DeliveryMonitoring onNavigate={c.onNavigate} />, "failed suppression"),
    ] },
    { key: "integrations", label: "Integrations and automation", icon: "integrations", items: [
      page("registry", "Integration registry", (c) => <P.IntegrationRegistry onNavigate={c.onNavigate} />, "connections health"),
      page("oauth", "OAuth applications", () => <P.OauthApps />, "google calendar gmail"),
      page("n8n", "n8n configuration", () => <P.N8nConfig />, "workflow dispatcher"),
      page("monitoring", "Automation monitoring", (c) => <P.AutomationMonitoring openBusiness={c.openBusiness} />, "executions failures"),
      page("webhooks", "Webhooks", () => <P.Webhooks />, "endpoints signature signing"),
    ] },
    { key: "security", label: "Security and privacy", icon: "security", items: [
      page("overview", "Security overview", () => <P.SecurityOverview />, "incidents suspicious"),
      page("isolation", "Data isolation", () => <P.DataIsolation />, "rls tenant row level"),
      page("secrets", "Secrets and credentials", () => <P.Secrets />, "keys rotation"),
      page("retention", "Data retention", (c) => <P.Retention me={c.me} />, "retention recording transcript"),
      page("privacy", "Privacy controls", (c) => <P.PrivacyControls onGo={c.onGo} />, "data requests consent"),
      page("audit", "Security audit", (c) => <P.SecurityAudit onNavigate={c.onNavigate} />, "audit log"),
    ] },
    { key: "alerts", label: "Notifications and alerts", icon: "alerts", items: [
      page("rules", "Alert rules", () => <P.AlertRules />, "severity escalation"),
      page("channels", "Notification channels", () => <P.NotificationChannels />, "email in-app"),
      page("history", "Notification history", (c) => <P.NotificationHistory me={c.me} />, "acknowledge resolve"),
    ] },
    { key: "support", label: "Support and service operations", icon: "support", items: [
      page("health", "Service health", () => <HealthPanel />, "providers status"),
      page("incidents", "Incident management", () => <IncidentsPanel />, "incident outage"),
      page("logs", "System logs", (c) => <><FailedEventsPanel onOpenBusiness={c.openBusiness} /><P.AutomationMonitoring openBusiness={c.openBusiness} /></>, "errors failed jobs correlation"),
    ] },
    { key: "analytics", label: "Analytics and reporting", icon: "analytics", items: [
      page("global", "Global analytics", () => <P.GlobalAnalytics />, "growth revenue usage retention"),
      page("reporting", "Reporting configuration", () => <P.ReportingConfig />, "scheduled reports"),
      page("quality", "Data quality", () => <P.DataQuality />, "duplicates unmatched"),
    ] },
    { key: "legal", label: "Legal, policy and documents", icon: "legal", items: [
      page("documents", "Legal documents", (c) => <P.LegalDocuments me={c.me} />, "terms privacy dpa cookie ai disclosure"),
      page("versions", "Document versioning", (c) => <P.LegalVersioning me={c.me} />, "publish review acceptance"),
      page("policy", "Policy configuration", (c) => <P.PolicyConfig onGo={c.onGo} />, "retention recording consent"),
    ] },
    { key: "developer", label: "Developer and API", icon: "dev", items: [
      page("api", "API management", () => <P.ApiManagement />, "keys scopes"),
      page("environment", "Environment configuration", () => <P.Environment />, "environment config validation"),
      page("system", "System configuration", () => <P.SystemConfig />, "feature flags history"),
    ] },
    { key: "profile", label: "Administrator profile", icon: "profile", items: [
      page("me", "My profile", (c) => <MyProfilePanel email={c.email} />, "name picture"),
      page("security", "Account security", (c) => <AccountSecurityPanel email={c.email} />, "password mfa sessions revoke devices login history"),
      page("notifications", "Personal notifications", () => <P.AdminNotifications />, "email alerts digest admin notifications"),
      page("appearance", "Appearance", () => <AppearancePanel />, "theme glass dark background wallpaper picture sidebar dock look notification sound chime"),
      page("signout", "Sign out", (c) => <SignOutPanel who="you" onSignOut={c.onSignOut} />, "logout"),
    ] },
  ];
}

const REGISTRY = registry();

export default function SettingsPage({ onNavigate, onOpenBusiness, onOpenSetup, onSignOut, section, sub }) {
  const [me, setMe] = useState(null);
  const [email, setEmail] = useState("");
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    callOwnerFunction("me_admin").then((m) => live && setMe(m)).catch((err) => live && setError(err.message));
    supabase.auth.getUser().then(({ data }) => live && setEmail(data?.user?.email ?? ""));
    return () => { live = false; };
  }, []);
  if (error) return <section className="owner-page"><Banner tone="error">Couldn't load Settings: {error}</Banner></section>;
  if (!me) return <section className="owner-page"><Loading /></section>;
  const context = {
    me, email, onNavigate, onSignOut, openBusiness: onOpenBusiness, openSetup: onOpenSetup,
    onGo: (path) => navigate(`/settings/${path}`),
  };
  return (
    <SettingsWorkspace
      description={`Platform administration · signed in as ${me.roleLabel}${me.mfa ? " with two-step sign-in" : ""}`}
      registry={REGISTRY} category={section} item={sub} base="/settings" go={navigate} Icon={Glyph} context={context} />
  );
}
