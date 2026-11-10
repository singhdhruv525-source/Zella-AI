import { retryAppearanceSave, useAppearanceSave } from "./appearance";
import { usePath } from "./router";

// Shown anywhere in the admin dashboard or the CRM when a look change made outside Settings (for example the sidebar's
// dock button) couldn't be saved to the account. The Appearance settings page shows its own message instead.
export function AppearanceSaveNotice() {
  const save = useAppearanceSave();
  const path = usePath();
  if (save.status !== "failed" || /\/appearance$/.test(path)) return null;
  return (
    <div className="zella-save-notice" role="alert">
      <span>Your look changed on this device only: it wasn't saved to your account ({save.error}).</span>
      <button type="button" onClick={retryAppearanceSave}>Try again</button>
    </div>
  );
}
