// What the record-files content check said about one upload, in plain words. A file only becomes visible to the rest
// of the team once the check has passed ("ready"); until then only its uploader sees it, as waiting to be checked.

const FILE_ERRORS = {
  BAD_FILE_TYPE: "Only photos (JPEG, PNG, WEBP, HEIC) and PDFs can be added.",
  FILE_TOO_BIG: "Files must be 10 MB or smaller.",
  TOO_MANY_FILES: "A record can hold 50 files. Remove some first.",
  UPLOAD_MISSING: "The upload didn't finish. Discard it and add the file again.",
  NOT_ALLOWED: "You can't add files to this record.",
};
export { FILE_ERRORS };

// `res` is the result of supabase.functions.invoke("record-files", { body: { action: "check", file_id } }).
// Returns { state: "ready" | "rejected" | "waiting" | "failed", message }.
export async function checkOutcome(res, fileName) {
  if (!res?.error) {
    const status = res?.data?.status;
    if (status === "ready" || res?.data?.ok) return { state: "ready", message: "" };
    if (status === "rejected") return { state: "rejected", message: `${fileName} wasn't added: it didn't pass the file check.` };
    if (status === "removed") return { state: "rejected", message: `${fileName} was discarded.` };
    return { state: "waiting", message: `${fileName} is uploaded but hasn't been checked yet. Use Check again.` };
  }
  let answer = null;
  try { answer = await res.error.context?.json?.(); } catch { /* not JSON */ }
  if (answer?.status === "rejected") return { state: "rejected", message: `${fileName} wasn't added: ${answer.reason ?? "it didn't pass the file check"}.` };
  if (answer?.error && FILE_ERRORS[answer.error]) {
    // the check refused it outright: nothing is waiting any more except an upload that never arrived
    return { state: answer.error === "UPLOAD_MISSING" ? "waiting" : "failed", message: `${fileName}: ${FILE_ERRORS[answer.error]}` };
  }
  return { state: "waiting", message: `${fileName} is uploaded but couldn't be checked yet. It stays hidden from your team until it is: use Check again below.` };
}
