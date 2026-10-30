import { useState } from "react";
import { supabase } from "../supabase";
import { passwordProblems } from "../formValidation";
import { finishMfaEnrollment, mfaStatus, removeMfaFactor, startMfaEnrollment } from "../mfa";
import { Banner, Card, Confirm, Facts, Field, LoadState, SaveBar, Table, useAsync, useForm, when } from "./SettingsKit";
import { friendly } from "../BusinessShared";

// Personal settings shared by admins and business users: they only ever touch
// the signed-in person's own account.

const say = (error) => {
  const m = error?.message ?? String(error);
  const codes = {
    BAD_PHONE: "Enter the mobile number with its country code, for example +1 555 123 4567.",
    USE_SIGN_OUT: "That's this device. Use Sign out instead.",
    NOT_SIGNED_IN: "Your session has ended. Please sign in again.",
    BAD_AVATAR_URL: "Upload the picture here so it's stored with Zella.",
  };
  const code = Object.keys(codes).find((k) => m.includes(k));
  return code ? codes[code] : /does not exist|schema cache|Could not find the function/i.test(m) ? "This needs the latest Zella database update." : m;
};

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(say(error));
  return data;
}

// Uploads an image to the brand-assets bucket and returns its public address.
export async function uploadImage(path, file) {
  if (!["image/png", "image/jpeg", "image/webp"].includes(file.type)) throw new Error("Choose a PNG, JPEG or WebP image.");
  if (file.size > 2 * 1024 * 1024) throw new Error("The image must be 2 MB or smaller.");
  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
  const full = `${path}-${Date.now()}.${ext}`;
  const { error } = await supabase.storage.from("brand-assets").upload(full, file, { contentType: file.type, upsert: false });
  if (error) throw new Error(/bucket not found/i.test(error.message) ? "Image storage isn't set up yet (needs the latest Zella database update)." : /row-level security|unauthorized/i.test(error.message) ? "You don't have permission to upload this image." : error.message);
  return supabase.storage.from("brand-assets").getPublicUrl(full).data.publicUrl;
}

export function MyProfilePanel({ email }) {
  const state = useAsync(async () => {
    const { data: { user } } = await supabase.auth.getUser();
    return { user, profile: (await rpc("zella_my_profile")) ?? {} };
  }, []);
  return <LoadState state={state}>{(d) => <ProfileForm email={email} user={d.user} profile={d.profile} onSaved={state.reload} />}</LoadState>;
}

function ProfileForm({ email, user, profile, onSaved }) {
  const form = useForm({ first: profile.first_name ?? "", last: profile.last_name ?? "", phone: profile.phone ?? "" });
  const [avatar, setAvatar] = useState(profile.avatar_url ?? null);
  const [pic, setPic] = useState({ busy: false, error: "" });
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  async function upload(file) {
    if (!file) return;
    setPic({ busy: true, error: "" });
    try {
      const url = await uploadImage(`user/${user.id}/avatar`, file);
      setAvatar(await rpc("zella_set_my_avatar", { p_url: url }));
      setPic({ busy: false, error: "" });
    } catch (err) {
      setPic({ busy: false, error: err.message });
    }
  }
  return (
    <>
      <Card title="Your details" sub={`Signed in as ${email}. Your email is your sign-in and can't be changed here.`}>
        <div className="zs-grid">
          <Field label="First name"><input value={form.values.first} onChange={form.set("first")} maxLength={100} autoComplete="given-name" /></Field>
          <Field label="Last name"><input value={form.values.last} onChange={form.set("last")} maxLength={100} autoComplete="family-name" /></Field>
          <Field label="Mobile number" hint="With country code. Used for urgent text alerts you switch on." full>
            <input value={form.values.phone} onChange={form.set("phone")} placeholder="+15551234567" inputMode="tel" autoComplete="tel" />
          </Field>
        </div>
        <SaveBar form={form} onSave={() => form.save(async (v) => {
          await rpc("zella_save_my_profile", { p_first_name: v.first, p_last_name: v.last, p_phone: v.phone.replace(/[\s()-]/g, "") || null });
          onSaved();
        })} />
      </Card>
      <Card title="Profile picture" sub="PNG, JPEG or WebP, up to 2 MB.">
        <ul className="zs-rows"><li>
          <div>{avatar ? <img src={avatar} alt="" width="56" height="56" style={{ borderRadius: "50%", objectFit: "cover" }} /> : <small>No picture yet.</small>}</div>
          <label className="zs-btn sm">{pic.busy ? "Uploading…" : avatar ? "Replace" : "Upload"}
            <input type="file" accept="image/png,image/jpeg,image/webp" hidden disabled={pic.busy} onChange={(e) => upload(e.target.files?.[0])} />
          </label>
          {avatar && <button type="button" className="zs-btn sm" disabled={pic.busy} onClick={async () => { try { setAvatar(await rpc("zella_set_my_avatar", { p_url: null })); } catch (err) { setPic({ busy: false, error: err.message }); } }}>Remove</button>}
        </li></ul>
        <Banner tone="error">{pic.error}</Banner>
      </Card>
      <Card title="Language and time">
        <Facts rows={[["Language", "English (US). Other languages aren't available yet."], ["Times are shown in", zone.replace(/_/g, " ") + " (this device's time zone)"]]} />
      </Card>
    </>
  );
}

export function AccountSecurityPanel({ email }) {
  return (
    <>
      <PasswordCard email={email} />
      <MfaCard />
      <SessionsCard />
    </>
  );
}

function PasswordCard({ email }) {
  const form = useForm({ password: "", confirm: "" });
  const [sent, setSent] = useState("");
  const missing = form.values.password ? passwordProblems(form.values.password) : [];
  return (
    <Card title="Password">
      <div className="zs-grid">
        <Field label="New password" error={missing.length ? `Still needs: ${missing.join(", ")}` : ""}>
          <input type="password" value={form.values.password} onChange={form.set("password")} autoComplete="new-password" />
        </Field>
        <Field label="Confirm new password" error={form.values.confirm && form.values.confirm !== form.values.password ? "The two passwords don't match." : ""}>
          <input type="password" value={form.values.confirm} onChange={form.set("confirm")} autoComplete="new-password" />
        </Field>
      </div>
      <SaveBar form={form} label="Change password" disabled={missing.length > 0 || form.values.password !== form.values.confirm}
        onSave={() => form.save(async (v) => {
          const { error } = await supabase.auth.updateUser({ password: v.password });
          if (error) throw new Error(/reauthenticat|recent/i.test(error.message) ? "For safety, use the email link below to change it." : error.message);
          return { password: "", confirm: "" };
        }, "Password changed.")} />
      <p className="zs-muted">
        Or <button type="button" className="zs-link" onClick={async () => {
          const { error } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/welcome` });
          setSent(error ? `Couldn't send: ${error.message}` : `A link is on its way to ${email}.`);
        }}>email me a link</button> to change it. {sent}
      </p>
    </Card>
  );
}

function MfaCard() {
  const state = useAsync(mfaStatus, []);
  const [setup, setSetup] = useState(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [removing, setRemoving] = useState(null);
  const step = async (fn) => {
    setBusy(true);
    setError("");
    try { await fn(); } catch (err) { setError(friendly(err)); } finally { setBusy(false); }
  };
  return (
    <Card title="Two-step sign-in" sub="After your password, enter a code from an authenticator app (Google Authenticator, 1Password, Authy and similar).">
      <LoadState state={state}>{(s) => (
        <>
          <Facts rows={[["Status", s.enrolled ? "On" : "Off"], ["This session", s.level === "aal2" ? "Verified with a code" : "Password only"]]} />
          {s.enrolled && s.factors.map((f) => (
            <div key={f.id} className="zs-savebar">
              <span className="zs-savebar-state">{f.friendly_name || "Authenticator app"} · added {when(f.created_at)}</span>
              <button type="button" className="zs-btn danger-outline sm" onClick={() => setRemoving(f)}>Remove</button>
            </div>
          ))}
          {!s.enrolled && !setup && <button type="button" className="zs-btn primary" style={{ marginTop: 12 }} disabled={busy}
            onClick={() => step(async () => setSetup(await startMfaEnrollment()))}>Set up an authenticator app</button>}
          {setup && (
            <div style={{ marginTop: 12 }}>
              <p className="zs-muted">Scan this with your authenticator app, or type the key in by hand. Then enter the 6-digit code it shows.</p>
              <img src={setup.qr} alt="QR code for your authenticator app" width="180" height="180" />
              <p className="zs-muted">Key: <code>{setup.secret}</code></p>
              <div className="zs-grid">
                <Field label="Code from the app"><input inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} /></Field>
              </div>
              <div className="zs-savebar">
                <span className="zs-savebar-state" />
                <button type="button" className="zs-btn" onClick={() => { setSetup(null); setCode(""); }} disabled={busy}>Cancel</button>
                <button type="button" className="zs-btn primary" disabled={busy} onClick={() => step(async () => { await finishMfaEnrollment(setup.factorId, code); setSetup(null); setCode(""); state.reload(); })}>Turn on</button>
              </div>
            </div>
          )}
          <Banner tone="error">{error}</Banner>
        </>
      )}</LoadState>
      {removing && <Confirm title="Remove two-step sign-in?" danger confirmLabel="Remove" onClose={() => setRemoving(null)}
        onConfirm={async () => { await removeMfaFactor(removing.id); state.reload(); }}>
        Signing in will need only your password again.
      </Confirm>}
    </Card>
  );
}

function SessionsCard() {
  const state = useAsync(() => rpc("zella_my_sessions"), []);
  const [notice, setNotice] = useState({ text: "", error: "" });
  const [confirmAll, setConfirmAll] = useState(false);
  const device = (ua) => {
    if (!ua) return "Unknown device";
    const browser = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "Browser";
    const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
    return `${browser}${os ? ` on ${os}` : ""}`;
  };
  async function revoke(s) {
    try {
      await rpc("zella_revoke_my_session", { p_session_id: s.id });
      setNotice({ text: "Signed out of that device. It can't refresh its sign-in anymore; an open page there stops working within the hour.", error: "" });
      state.reload();
    } catch (err) { setNotice({ text: "", error: err.message }); }
  }
  return (
    <Card title="Devices and sessions" sub="Where you're signed in, newest activity first. Ended sessions drop off this list."
      actions={<button type="button" className="zs-btn sm" onClick={() => setConfirmAll(true)}>Sign out other devices</button>}>
      <Banner tone="success">{notice.text}</Banner>
      <Banner tone="error">{notice.error}</Banner>
      <LoadState state={state}>{(rows) => (
        <Table rows={rows} empty="No sessions found." columns={[
          ["Device", (s) => <>{device(s.user_agent)}{s.current && <> · <strong>this device</strong></>}</>],
          ["Signed in", (s) => when(s.created_at)],
          ["Last active", (s) => when(s.last_active_at)],
          ["IP address", (s) => s.ip ?? "—"],
          ["Code used", (s) => (s.aal === "aal2" ? "Yes" : "No")],
          ["", (s) => (s.current ? null : <button type="button" className="zs-btn sm" onClick={() => revoke(s)}>Sign out</button>)],
        ]} />
      )}</LoadState>
      {confirmAll && <Confirm title="Sign out of every other device?" confirmLabel="Sign out others" onClose={() => setConfirmAll(false)}
        onConfirm={async () => {
          const { error } = await supabase.auth.signOut({ scope: "others" });
          if (error) throw error;
          setNotice({ text: "Signed out everywhere else. This device stays signed in.", error: "" });
          state.reload();
        }}>You stay signed in here.</Confirm>}
    </Card>
  );
}

export function SignOutPanel({ onSignOut, who }) {
  const [open, setOpen] = useState(false);
  return (
    <Card title="Sign out" sub={`Signs ${who} out of this device only. Other people and the subscription aren't affected.`}>
      <button type="button" className="zs-btn primary" onClick={() => setOpen(true)}>Sign out</button>
      {open && <Confirm title="Sign out of Zella?" confirmLabel="Sign out" onClose={() => setOpen(false)} onConfirm={onSignOut}>You'll go back to the sign-in page.</Confirm>}
    </Card>
  );
}
