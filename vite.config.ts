import { defineConfig } from 'vite';

// webR's fastest comms channel uses SharedArrayBuffer, which the browser only
// exposes to cross-origin-isolated pages. These headers opt us in for both the
// dev server and `vite preview`. Without them webR still works via a slower
// fallback channel, but isolation keeps R execution snappy.
const crossOriginIsolation = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
};

export default defineConfig({
  server: { headers: crossOriginIsolation },
  preview: { headers: crossOriginIsolation },
  // webr ships a worker that Vite would otherwise try to pre-bundle and choke on.
  optimizeDeps: { exclude: ['webr'] },
});
