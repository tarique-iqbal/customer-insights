// Checked-in stub — Vite's dev server and Compose serve this as-is, so
// api/http.ts falls through to import.meta.env.VITE_API_URL, matching
// current dev behavior exactly. The prod nginx image overwrites this file
// at container start with the real runtime API URL (see
// docker/web-user/generate-env.sh).
window.__ENV__ = {};
