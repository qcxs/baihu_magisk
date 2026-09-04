import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// KernelSU WebView loads from file:///android_asset/... or module webroot.
// base: '' ensures relative asset paths (./assets/...) so it works
// regardless of the serving context.
export default defineConfig({
  plugins: [vue()],
  base: '',
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    cssCodeSplit: false,
  },
})