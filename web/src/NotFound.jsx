import "./OwnerDashboard.css";
import "./OwnerPages.css";

// An address that matches no page, for someone who isn't signed in (publicRoute.js, "unknown"). It must not fall
// through to the admin sign in; it says so plainly and offers the way home. When the saved sign in couldn't be read
// (unavailable), it says that instead, with Try again, because the person may be a signed in admin.
export default function NotFound({ unavailable = false, onRetry }) {
  return (
    <main className="cp-page">
      <section className="cp-card" role={unavailable ? "alert" : undefined}>
        <div className="cp-brand">
          <div className="owner-brand-mark" aria-hidden="true">Z</div>
          <span>Zella <span className="cp-ai">Voice</span></span>
        </div>
        {unavailable ? (
          <>
            <h1>This page couldn't be opened</h1>
            <p>We couldn't check whether you're signed in. Nothing was changed. Try again, or go to the home page.</p>
            <button type="button" className="owner-primary-button cp-button" onClick={onRetry}>Try again</button>
            <p className="cp-small"><a href="/">Go to the home page</a></p>
          </>
        ) : (
          <>
            <h1>Page not found</h1>
            <p>There's no page at this address. Check that it's typed correctly, or go to the home page.</p>
            <a className="owner-primary-button cp-button" href="/">Go to the home page</a>
          </>
        )}
      </section>
    </main>
  );
}
