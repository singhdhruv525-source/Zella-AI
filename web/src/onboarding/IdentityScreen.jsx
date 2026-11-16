import { useEffect, useState } from "react";
import { DOCUMENT_MAX_BYTES, DOCUMENT_TYPES } from "../onboardingConfig";
import { Actions, ErrorText, useAction } from "./kit";
import { errorWords, identityPassed, identityState, isNotReady, uploadKinds } from "./steps";

// Screen 4, Verify your identity. No identity provider is chosen yet (contract §3, identity_provider "none"), so the
// working path is a manual upload of the same verification documents the Create Business wizard collects: the same
// file types and size limit (onboardingConfig.js), the same private bucket through a one time upload link (§5.8). A
// Zella Voice admin checks them in Verification. The owner sees Documents needed, Checking, Verified, Try again or In
// review, always as the server reports it, and can move on only once it says Verified.

const KIND_WORDS = {
  owner_identity: ["Your photo ID", "Passport, driver's license or national ID card. Make sure your name and photo are clear."],
  business_registration: ["Business registration", "Business license, certificate of incorporation, or another official record of the business."],
};
const DOC_WORDS = { pending_review: "Waiting for review", verified: "Verified", rejected: "Not accepted" };
const STATE_TEXT = {
  needed: "Upload both documents below. We'll check them and tell you here.",
  checking: "We have your documents and we're checking them now. It usually takes one working day. You can choose Finish later; this page shows the answer when you come back.",
  verified: "You're verified. Thank you.",
  try_again: "One of your documents wasn't accepted. See why below, then upload a new copy.",
  in_review: "A person on the Zella Voice team is now reviewing your documents by hand. This page shows the answer when it's done.",
};
const ICON = { verified: "verified", try_again: "error", in_review: "person_search", checking: "hourglass_top", needed: "upload_file" };

export function IdentityScreen({ api, state, onState, onComplete }) {
  const identity = state.identity ?? {};
  const st = identityState(identity);
  const [problem, setProblem] = useState("");
  const [busy, setBusy] = useState("");
  const [checking, setChecking] = useState(false);
  const finish = useAction();
  const kinds = uploadKinds(identity);
  const docs = Array.isArray(identity.documents) ? identity.documents : [];
  const passed = identityPassed(identity);
  const id = state.business_id;

  async function refresh() {
    setChecking(true);
    try { onState({ ...state, identity: await api.identityStatus(id) }); setProblem(""); }
    catch (err) { setProblem(errorWords(err)); }
    finally { setChecking(false); }
  }
  // while documents are being checked, look again every 30 seconds while the page is in view (the contract allows 15)
  useEffect(() => {
    if (!["checking", "in_review"].includes(st.key)) return undefined;
    const t = setInterval(() => { if (document.visibilityState === "visible") refresh(); }, 30000);
    return () => clearInterval(t);
  }, [st.key]); // eslint-disable-line react-hooks/exhaustive-deps

  async function upload(kind, file) {
    setProblem("");
    if (!file) return;
    if (!DOCUMENT_TYPES.includes(file.type)) return setProblem("Upload a PDF or a photo (JPG, PNG, WEBP or HEIC).");
    if (file.size > DOCUMENT_MAX_BYTES) return setProblem("Files must be 10 MB or smaller.");
    setBusy(kind);
    try {
      const meta = { businessId: id, kind, fileName: file.name, mimeType: file.type, size: file.size };
      const { path, token } = await api.identityUploadUrl(meta);
      await api.uploadFile(path, token, file);
      const res = await api.identityUploadConfirm({ ...meta, path });
      onState({ ...state, identity: res.identity });
    } catch (err) {
      setProblem(isNotReady(err) ? "Uploading isn't ready yet. Choose Finish later and come back soon." : errorWords(err));
    } finally {
      setBusy("");
    }
  }

  const shownKinds = [...new Set([...kinds, ...docs.map((d) => d.kind)])].filter((k) => KIND_WORDS[k]);
  return (
    <>
      <p className="zob-lead">Before your receptionist answers calls, we check that you are who you say and that the business is real. Your files are private: only the Zella Voice team can open them.</p>
      <div className={`zob-status tone-${st.tone}`} role="status" aria-live="polite">
        <span className="ba-icon" aria-hidden="true">{ICON[st.key]}</span>
        <div>
          <strong>{st.label}</strong>
          <p>{STATE_TEXT[st.key]}</p>
          {st.key === "try_again" && Number(identity.attempts_allowed) > 0 && <p>After {identity.attempts_allowed} tries, a person on our team reviews your documents by hand.</p>}
        </div>
        {["checking", "in_review"].includes(st.key) && <button type="button" className="ba-btn sm" disabled={checking} onClick={refresh}>{checking ? "Checking…" : "Check again"}</button>}
      </div>

      <IdentityProviderSlot rules={state.rules} />

      {shownKinds.length > 0 && !passed && (
        <ul className="zob-docs" aria-label="Your documents">
          {shownKinds.map((kind) => {
            const doc = docs.find((d) => d.kind === kind);
            const [label, hint] = KIND_WORDS[kind];
            const canUpload = kinds.includes(kind);
            return (
              <li key={kind} className={`zob-doc ${doc ? doc.status : ""}`}>
                <span className="ba-icon" aria-hidden="true">{kind === "owner_identity" ? "badge" : "description"}</span>
                <div className="zob-doc-main">
                  <strong>{label}</strong>
                  <small>{doc ? DOC_WORDS[doc.status] ?? "Sent" : hint}</small>
                  {doc?.status === "rejected" && doc.review_note && <small className="zob-doc-note">Why: {doc.review_note}</small>}
                </div>
                {canUpload && (
                  <label className={`ba-btn sm zob-upload ${busy === kind ? "busy" : ""}`}>
                    <input type="file" accept={DOCUMENT_TYPES.join(",")} disabled={Boolean(busy)} aria-label={`${doc ? "Upload a new copy of" : "Upload"} ${label.toLowerCase()}`}
                      onChange={(e) => { upload(kind, e.target.files?.[0]); e.target.value = ""; }} />
                    <span aria-hidden="true">{busy === kind ? "Uploading…" : doc ? "Upload a new copy" : "Upload"}</span>
                  </label>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {kinds.length > 0 && <p className="zob-hint">PDF or a photo, up to 10 MB each.</p>}
      <ErrorText>{problem || finish.error}</ErrorText>
      <Actions>
        <button type="button" className="ba-btn primary" disabled={!passed || finish.busy || Boolean(busy)} onClick={() => finish.run(() => onComplete("identity"))}
          aria-describedby={passed ? undefined : "zob-id-wait"}>{finish.busy ? "One moment…" : "Continue"}</button>
        {!passed && <span className="zob-hint" id="zob-id-wait">You can continue once you're verified.</span>}
      </Actions>
    </>
  );
}

// Where an identity provider's own check (its widget, or a link to it) goes once one is chosen. That is an open
// decision for the owner (Persona, Stripe Identity, or manual upload); while the server's rule says "none", nothing
// shows here and the manual upload above is the way through. A provider would add its widget in this one place.
function IdentityProviderSlot({ rules }) {
  const provider = rules?.identity_provider;
  if (!provider || provider === "none") return null;
  return (
    <div className="zob-provider" data-provider={provider} role="status">
      <p className="zob-muted">Checking your ID online isn't available in this version yet. Upload your documents instead.</p>
    </div>
  );
}
