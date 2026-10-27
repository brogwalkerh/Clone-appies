import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// In dev the game server (`pnpm --filter @starfarers/server dev`, :3000) is proxied
// so the client can use same-origin sockets exactly as in production.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { '/socket.io': { target: 'http://localhost:3000', ws: true } },
  },
  build: { outDir: 'dist', sourcemap: true },
});
