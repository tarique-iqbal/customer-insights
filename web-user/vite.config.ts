import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import * as path from 'path';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  envPrefix: 'VITE_',
  server: {
    host: true,
    port: 5173,
    strictPort: true,
    // Vite rejects unrecognized Host headers by default (DNS-rebinding
    // protection). Compose reaches it as "localhost"; the kind Ingress
    // reaches it as "app.localtest.me" — allow both, not every host.
    allowedHosts: ['localhost', 'app.localtest.me'],
    watch: {
      usePolling: true,
      interval: 500,
    },
    hmr: {
      clientPort: 5173,
      protocol: 'ws',
    },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/setupTests.ts'],
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
    coverage: {
      provider: 'istanbul',
    },
  },
});
