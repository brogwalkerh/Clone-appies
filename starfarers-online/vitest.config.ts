import { defineConfig } from 'vitest/config';

// Workspace-level config: every package that ships a vitest.config.ts is a project.
// `pnpm test` from this directory runs all of them.
export default defineConfig({
  test: {
    projects: ['./*/vitest.config.ts'],
  },
});
