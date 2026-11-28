import { useEffect } from "react";
import { payRedirect } from "./payRedirect.js";

// The old /pay addresses redirect into the CRM (see payRedirect.js).
export default function PayPage() {
  useEffect(() => { window.location.replace(payRedirect(window.location.pathname, window.location.search)); }, []);
  return <p className="zpay-loading" role="status">Opening your payments…</p>;
}
