import "./OwnerDashboard.css";
import "./OwnerPages.css";

// A customer link (reschedule /r/, unsubscribe /u/, waitlist /w/) that is incomplete: often a link split across two
// lines in an email or text. The customer isn't signed in and must not land on the admin sign-in.
export default function BrokenLink() {
  return (
    <main className="cp-page">
      <section className="cp-card" role="status">
        <div className="cp-brand">
          <div className="owner-brand-mark" aria-hidden="true">Z</div>
          <span>Zella <span className="cp-ai">Voice</span></span>
        </div>
        <h1>This link isn't complete</h1>
        <p>Part of the link seems to be missing. Open the full link from your text or email (it may have been split across two lines), or contact the business directly.</p>
      </section>
    </main>
  );
}
