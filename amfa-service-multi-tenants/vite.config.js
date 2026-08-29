import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import legacy from '@vitejs/plugin-legacy';

export default defineConfig(() => {
	return {
		build: {
			outDir: 'build',
			rollupOptions: {
				external: '/awsconfig.json',
			}
		},
		plugins: [
			react(),
			// Legacy bundle for non-ESM engines: the Office sign-in webview on
			// Windows Server 2022 / Win10 (WAM broker = EdgeHTML, ADAL = IE11
			// MSHTML) ignores <script type="module">, rendering a blank page.
			legacy({
				targets: ['edge >= 18', 'ie >= 11'],
				// core-js only covers ES features; fetch() is a DOM API used at
				// startup (src/index.jsx tenant config load) and missing in IE11.
				additionalLegacyPolyfills: ['whatwg-fetch'],
			}),
		],
	};
});