import { defineConfig } from 'vite'
import { resolve }      from 'path'

// MPA — un entrypoint HTML por página.
// Los .html son generados por pug (npm run pug / prebuild).
export default defineConfig({
  root: __dirname,
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
