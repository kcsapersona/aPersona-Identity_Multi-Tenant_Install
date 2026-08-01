/// <reference types="vitest" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'node:path';

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => ({
    plugins: [react()],
    resolve: mode === 'test' ? {
        alias: {
            '/amfaext.js': path.resolve(__dirname, 'src/test/amfaext.js'),
        },
    } : undefined,
    define: {
        'process.env': process.env,
    },
    server: {
        host: true,
    },
    build: {
        // react-admin + MUI + React have deep circular dependencies that prevent
        // reliable chunk splitting. Suppress the warning for the single bundle.
        chunkSizeWarningLimit: 1800,
        rollupOptions: {
            external: '/amfaext.js',
        },
    },
    test: {
        environment: 'jsdom',
        setupFiles: './src/test/setup.js',
        include: ['src/**/*.test.{js,jsx}'],
    },
    base: './',
}));
