import { callOwnerFunction } from "../../CreateBusinessWizard";
import { Card, LoadState, Needs, Pill, useAsync } from "../SettingsKit";

// Settings, OAuth applications (SET-OAUTH-CHECKS): whether the Google and Microsoft calendar app keys are set as server
// secrets, from the server configuration check (platform_status). Set or not set only: values never leave the server.
const APPS = [
  ["Google Calendar", "GOOGLE_CALENDAR_CLIENT_ID", "GOOGLE_CALENDAR_CLIENT_SECRET"],
  ["Microsoft calendar", "MICROSOFT_CALENDAR_CLIENT_ID", "MICROSOFT_CALENDAR_CLIENT_SECRET"],
];

export default function OauthApps() {
  const state = useAsync(() => callOwnerFunction("platform_status"), []);
  return (
    <LoadState state={state}>{(s) => {
      const set = new Map((s.configuration ?? []).map((c) => [c.key, c.set]));
      if (!set.has("GOOGLE_CALENDAR_CLIENT_ID")) {
        return <Needs title="The calendar app check needs the latest server update" have="Calendar connections still work as before.">Once the owner provision function is deployed, this shows whether each calendar app's keys are set.</Needs>;
      }
      return (
        <Card title="Calendar apps" sub="The app keys businesses use to connect their calendars. Set as server secrets; only whether each is set is shown.">
          <ul className="zs-checklist">
            {APPS.map(([name, id, secret]) => {
              const ok = set.get(id) && set.get(secret);
              return (
                <li key={name} className={ok ? "ok" : ""} data-oauth-app={name}>
                  <span className="zs-check-marker" aria-hidden="true">{ok ? "✓" : ""}</span>
                  <span title={`Secrets ${id} and ${secret}`}><strong>{name}</strong>
                    <small>{ok ? "Client ID and secret are set" : set.get(id) || set.get(secret) ? `${set.get(id) ? "Client secret" : "Client ID"} is missing` : "Not set up: businesses can't connect this calendar yet"}</small></span>
                  <Pill tone={ok ? "success" : "warning"}>{ok ? "Set" : "Not set"}</Pill>
                </li>
              );
            })}
            <li className="ok" data-oauth-app="redirect">
              <span className="zs-check-marker" aria-hidden="true">✓</span>
              <span title="Secret CALENDAR_REDIRECT_URL"><strong>Return address after sign in</strong>
                <small>{set.get("CALENDAR_REDIRECT_URL") ? "Set to a custom address" : "Not set, so the calendar connect function's own address is used"}</small></span>
              <Pill tone="success">{set.get("CALENDAR_REDIRECT_URL") ? "Custom" : "Default"}</Pill>
            </li>
          </ul>
        </Card>
      );
    }}</LoadState>
  );
}
