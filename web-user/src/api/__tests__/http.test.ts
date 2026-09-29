import { describe, it, expect, afterEach, vi } from 'vitest';

describe('http baseURL resolution', () => {
  afterEach(() => {
    delete window.__ENV__;
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  it('uses window.__ENV__.VITE_API_URL when set (static prod build, runtime config)', async () => {
    window.__ENV__ = { VITE_API_URL: 'https://runtime.example.com' };

    const { default: http } = await import('@/api/http');

    expect(http.defaults.baseURL).toBe('https://runtime.example.com');
  });

  it('falls back to import.meta.env.VITE_API_URL when window.__ENV__ has none (dev server)', async () => {
    vi.stubEnv('VITE_API_URL', 'https://build-time.example.com');

    const { default: http } = await import('@/api/http');

    expect(http.defaults.baseURL).toBe('https://build-time.example.com');
  });

  it('falls back to the hardcoded default when neither is set', async () => {
    vi.stubEnv('VITE_API_URL', '');

    const { default: http } = await import('@/api/http');

    expect(http.defaults.baseURL).toBe('http://localhost:8080');
  });
});
