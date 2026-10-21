import { useEffect, useMemo, useRef, useState } from "react";
import {
  checkEmail, checkPhone, countryByIso, countryList, defaultCountryFromBrowser, flag,
  passwordProblems, passwordRules, PASSWORD_MAX, splitPhone, timeZoneGroups,
} from "./formValidation";
import "./formFields.css";

let counter = 0;
const useId = (prefix) => {
  const ref = useRef(null);
  if (ref.current === null) ref.current = `${prefix}-${++counter}`;
  return ref.current;
};

function FieldError({ id, text }) {
  if (!text) return null;
  return <p className="ff-error" id={id} role="alert">{text}</p>;
}

/* ---------------------------------------------------------------- Phone */

/**
 * Country picker + number box.
 * value: "+15551234567" when good, "?raw" when the number is wrong, "" when empty.
 * Show the error under the box once the person leaves it, or when showErrors is true.
 */
export function PhoneField({ value, onChange, required = false, disabled = false, showErrors = false, placeholder, id, label = "Phone number" }) {
  const errId = useId("ff-phone-err");
  const inputId = id || useId("ff-phone");
  const [iso, setIso] = useState(() => splitPhone(value, defaultCountryFromBrowser()).iso);
  const [text, setText] = useState(() => splitPhone(value, defaultCountryFromBrowser()).national);
  const [touched, setTouched] = useState(false);
  const last = useRef(value ?? "");
  const countries = useMemo(countryList, []);

  // When the saved value is replaced from outside (for example after a reload), show it.
  useEffect(() => {
    if ((value ?? "") === last.current) return;
    last.current = value ?? "";
    const next = splitPhone(value, iso);
    setIso(next.iso);
    setText(next.national);
  }, [value]); // eslint-disable-line react-hooks/exhaustive-deps

  const emit = (nextIso, nextText) => {
    const result = checkPhone(nextText, nextIso, { required });
    const out = result.value || (nextText.trim() ? `?${nextText.trim()}` : "");
    last.current = out;
    onChange(out);
  };

  const result = checkPhone(text, iso, { required });
  const error = touched || showErrors ? result.error : "";
  const country = countryByIso(iso);

  return (
    <div className={`ff ff-phone ${error ? "has-error" : ""} ${disabled ? "is-disabled" : ""}`}>
      <div className="ff-phone-row">
        <label className="ff-country" title={`${country.name ?? ""}`}>
          <span className="ff-country-shown" aria-hidden="true">
            <span className="ff-flag">{flag(country.iso)}</span>
            <span className="ff-dial">+{country.dial}</span>
          </span>
          <select
            aria-label={`${label}: country code`}
            value={iso}
            disabled={disabled}
            onChange={(e) => { setIso(e.target.value); setTouched(true); emit(e.target.value, text); }}
          >
            {countries.map((c) => (
              <option key={c.iso} value={c.iso}>{flag(c.iso)} {c.name} (+{c.dial})</option>
            ))}
          </select>
        </label>
        <input
          id={inputId}
          type="tel"
          inputMode="tel"
          autoComplete="tel-national"
          value={text}
          disabled={disabled}
          placeholder={placeholder || "Phone number"}
          aria-invalid={Boolean(error)}
          aria-describedby={error ? errId : undefined}
          onChange={(e) => { setText(e.target.value); emit(iso, e.target.value); }}
          onBlur={() => setTouched(true)}
        />
      </div>
      <FieldError id={errId} text={error} />
    </div>
  );
}

/* ---------------------------------------------------------------- Email */

export function EmailField({ value, onChange, required = false, disabled = false, showErrors = false, placeholder = "name@business.com", id, autoComplete = "email" }) {
  const errId = useId("ff-email-err");
  const [touched, setTouched] = useState(false);
  const error = touched || showErrors ? checkEmail(value, { required }) : "";
  return (
    <div className={`ff ${error ? "has-error" : ""}`}>
      <input
        id={id}
        type="email"
        inputMode="email"
        autoComplete={autoComplete}
        autoCapitalize="none"
        spellCheck={false}
        value={value}
        disabled={disabled}
        placeholder={placeholder}
        aria-invalid={Boolean(error)}
        aria-describedby={error ? errId : undefined}
        onChange={(e) => onChange(e.target.value)}
        onBlur={() => { setTouched(true); if (value !== value.trim()) onChange(value.trim()); }}
      />
      <FieldError id={errId} text={error} />
    </div>
  );
}

/* ------------------------------------------------------------- Timezone */

export function TimeZoneSelect({ value, onChange, disabled = false, id }) {
  const groups = useMemo(() => timeZoneGroups([value]), [value]);
  const [query, setQuery] = useState("");
  const q = query.trim().toLowerCase().replace(/\s+/g, "_");
  const shown = useMemo(() => {
    if (!q) return groups;
    return groups
      .map((g) => ({ ...g, items: g.items.filter((i) => i.zone.toLowerCase().includes(q) || i.label.toLowerCase().includes(q.replace(/_/g, " "))|| i.zone === value) }))
      .filter((g) => g.items.length);
  }, [groups, q, value]);
  const count = groups.reduce((n, g) => n + g.items.length, 0);
  return (
    <div className="ff ff-tz">
      <input
        type="search"
        className="ff-tz-search"
        placeholder={`Search ${count} time zones, like Kolkata or +05:30`}
        value={query}
        disabled={disabled}
        aria-label="Search time zones"
        onChange={(e) => setQuery(e.target.value)}
      />
      <select id={id} value={value} disabled={disabled} onChange={(e) => onChange(e.target.value)}>
        {shown.map((g) => (
          <optgroup key={g.region} label={g.region}>
            {g.items.map((i) => <option key={i.zone} value={i.zone}>{i.label}</option>)}
          </optgroup>
        ))}
      </select>
    </div>
  );
}

/* ------------------------------------------------------------- Password */

const Tick = ({ on }) => (
  <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" className="ff-tick">
    {on
      ? <path d="M3 8.5l3.2 3.2L13 4.8" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
      : <circle cx="8" cy="8" r="4.5" fill="none" stroke="currentColor" strokeWidth="1.6" />}
  </svg>
);

export function PasswordChecklist({ password }) {
  const rules = passwordRules(password);
  const missing = rules.filter((r) => !r.met);
  return (
    <div className="ff-rules" aria-live="polite">
      <ul>
        {rules.map((r) => (
          <li key={r.id} className={r.met ? "met" : ""}>
            <Tick on={r.met} />
            <span>{r.label}</span>
          </li>
        ))}
      </ul>
      <p className={`ff-rules-summary ${missing.length ? "" : "met"}`}>
        {missing.length ? `Still needed: ${missing.map((r) => r.short).join(", ")}.` : "Your password meets every requirement."}
      </p>
    </div>
  );
}

export function PasswordField({ value, onChange, disabled = false, showRules = true, autoComplete = "new-password", placeholder, id, showErrors = false }) {
  const [visible, setVisible] = useState(false);
  const [touched, setTouched] = useState(false);
  const errId = useId("ff-pw-err");
  const problems = passwordProblems(value);
  const error = (touched || showErrors) && !value ? "Enter a password." : "";
  return (
    <div className={`ff ff-password ${error ? "has-error" : ""}`}>
      <div className="ff-password-row">
        <input
          id={id}
          type={visible ? "text" : "password"}
          autoComplete={autoComplete}
          value={value}
          disabled={disabled}
          maxLength={PASSWORD_MAX + 20}
          placeholder={placeholder}
          aria-invalid={Boolean(error) || (touched && problems.length > 0)}
          onChange={(e) => onChange(e.target.value)}
          onBlur={() => setTouched(true)}
        />
        <button type="button" className="ff-reveal" onClick={() => setVisible((v) => !v)} aria-pressed={visible} disabled={disabled}>
          {visible ? "Hide" : "Show"}
        </button>
      </div>
      <FieldError id={errId} text={error} />
      {showRules && <PasswordChecklist password={value} />}
    </div>
  );
}

export function ConfirmPasswordField({ value, password, onChange, disabled = false, autoComplete = "new-password", id, showErrors = false }) {
  const [touched, setTouched] = useState(false);
  const errId = useId("ff-pw2-err");
  const mismatch = value && value !== password;
  const error = (touched || showErrors) ? (!value ? "Enter the password again." : mismatch ? "The passwords don't match." : "") : (mismatch && value.length >= password.length ? "The passwords don't match." : "");
  const matches = value && !mismatch;
  return (
    <div className={`ff ${error ? "has-error" : ""}`}>
      <input
        id={id}
        type="password"
        autoComplete={autoComplete}
        value={value}
        disabled={disabled}
        aria-invalid={Boolean(error)}
        aria-describedby={error ? errId : undefined}
        onChange={(e) => onChange(e.target.value)}
        onBlur={() => setTouched(true)}
      />
      <FieldError id={errId} text={error} />
      {matches && <p className="ff-ok"><Tick on /> Passwords match.</p>}
    </div>
  );
}
