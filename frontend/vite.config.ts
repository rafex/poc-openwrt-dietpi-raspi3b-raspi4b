import { defineConfig } from 'vite'
import { resolve }      from 'path'

// MPA — un entrypoint HTML por página.
// Los .html son generados por pug (npm run pug / prebuild).
export default defineConfig({
  root: __dirname,

  // ── Proxy de desarrollo ─────────────────────────────────────────────────────
  // En `npm run dev`, el frontend corre en :5173 y el backend Java en :5000.
  // El proxy reenvía /api/, /health y /events al backend sin necesidad de CORS
  // ni de levantar nginx durante el desarrollo.
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target:      'http://localhost:5000',
        changeOrigin: false,
      },
      '/health': {
        target:      'http://localhost:5000',
        changeOrigin: false,
      },
      // SSE: Vite dev server ya no bufferiza streaming, no hace falta configure
      '/events': {
        target:       'http://localhost:5000',
        changeOrigin: false,
      },
    },
  },

  build: {
    outDir:       'dist',
    emptyOutDir:  true,
    rollupOptions: {
      input: {
        index:     resolve(__dirname, 'index.html'),
        dashboard: resolve(__dirname, 'dashboard.html'),
        chat:      resolve(__dirname, 'chat.html'),
        terminal:  resolve(__dirname, 'terminal.html'),
        rulez:     resolve(__dirname, 'rulez.html'),
        reports:   resolve(__dirname, 'reports.html'),
      },
    },
  },

  css: {
    preprocessorOptions: {
      scss: {
        // Silencia la advertencia legacy de la API de Sass
        api: 'modern-compiler',
      },
    },
  },
})
