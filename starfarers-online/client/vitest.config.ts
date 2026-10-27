import react from '@vitejs/plugin-react';
import { defineConfig } from 'vitest/config';

// Picked up by the workspace config (../vitest.config.ts → projects) and runnable alone.
export default defineConfig({
  plugins: [react()],
  test: {
    name: 'client',
    environment: 'jsdom',
    setupFiles: ['./test/setup.ts'],
    include: ['test/**/*.test.ts', 'test/**/*.test.tsx'],
  },
});
