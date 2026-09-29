import axios from 'axios';

declare global {
  interface Window {
    // Written by docker/web-user's nginx entrypoint at container start (see
    // public/env.js) — vite build inlines import.meta.env.VITE_API_URL at
    // build time, so a static prod image needs this instead to pick up the
    // real URL at deploy time. The checked-in public/env.js stub sets this
    // to {}, so dev (Vite dev server) and Compose fall through to
    // import.meta.env.VITE_API_URL exactly as before.
    __ENV__?: {
      VITE_API_URL?: string;
    };
  }
}

const runtimeApiUrl = window.__ENV__?.VITE_API_URL;

const http = axios.create({
  baseURL: runtimeApiUrl || import.meta.env.VITE_API_URL || 'http://localhost:8080',
  headers: {
    'Content-Type': 'application/json',
  },
});

export default http;
