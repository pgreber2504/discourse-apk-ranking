// Pure URL → image-validity check used by composer + edit form.
// Returns one of: "empty", "invalid_url", "valid", "invalid".
// Race-condition handling (e.g. token counters) lives in the caller —
// this helper is intentionally stateless.
export function validateIconUrl(url) {
  const trimmed = (url ?? "").trim();

  if (!trimmed) {
    return Promise.resolve("empty");
  }

  if (!trimmed.match(/^https?:\/\/.+/)) {
    return Promise.resolve("invalid_url");
  }

  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve("valid");
    img.onerror = () => resolve("invalid");
    img.src = trimmed;
  });
}
