import { defineConfig } from 'astro/config';

export default defineConfig({
  output: 'static',
  site: 'https://trading.boredstudio.ai',
  vite: {
    build: { minify: false },
  },
});
