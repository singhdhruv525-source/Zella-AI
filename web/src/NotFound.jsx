import "./OwnerDashboard.css";
import "./OwnerPages.css";

// An address that matches no page, for someone who isn't signed in (publicRoute.js, "unknown"). It must not fall
// through to the admin sign in; it says so plainly and offers the way home.
export default function NotFound() {
  return (
    <main className="cp-page">
      <section className="cp-card">
        <div className="cp-brand">
          <div className="owner-brand-mark" aria-hidden="true">Z</div>
          <span>Zella <span className="cp-ai">Voice</span></span>
        </div>
        <h1>Page not found</h1>
        <p>There's no page at this address. Check that it's typed correctly, or go to the home page.</p>
        <a className="owner-primary-button cp-button" href="/">Go to the home page</a>
      </section>
    </main>
  );
}
