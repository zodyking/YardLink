import { cpSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import tailwindcss from '@tailwindcss/vite'

export default defineNuxtConfig({

  modules: [
    '@nuxt/eslint',
    'nuxt-auth-utils',
    '@vite-pwa/nuxt',
  ],

  devtools: { enabled: true },

  app: {
    head: {
      htmlAttrs: { lang: 'en' },
      meta: [
        { charset: 'utf-8' },
        { name: 'viewport', content: 'width=device-width, initial-scale=1.0, viewport-fit=cover, interactive-widget=resizes-content' },
        { name: 'theme-color', content: '#052543' },
        { name: 'apple-mobile-web-app-capable', content: 'yes' },
        { name: 'mobile-web-app-capable', content: 'yes' },
        { name: 'apple-mobile-web-app-status-bar-style', content: 'black-translucent' },
      ],
      link: [
        { rel: 'icon', type: 'image/png', sizes: '32x32', href: '/favicon-32.png?v=3' },
        { rel: 'icon', href: '/favicon.ico?v=3', sizes: '48x48' },
        { rel: 'apple-touch-icon', href: '/apple-touch-icon.png?v=3' },
        { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
        { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' },
        {
          rel: 'stylesheet',
          href: 'https://fonts.googleapis.com/css2?family=Open+Sans:wght@400;500;600;700;800&family=JetBrains+Mono:wght@500;600&display=swap',
        },
      ],
    },
  },

  css: ['~/assets/css/main.css', 'leaflet/dist/leaflet.css'],

  runtimeConfig: {
    /**
     * Nothing here is set by the employer. The container generates the
     * database address and session secret on first start; everything else is
     * entered in the web app (setup wizard, then Settings) and kept in the
     * database.
     */
    databaseUrl: '',
    databaseSsl: '',
    session: {
      password: '',
      /** Stay signed in for 30 days — a driver should not sign in every shift. */
      maxAge: 60 * 60 * 24 * 30,
      cookie: {
        // Off here so a first install on plain http works out of the box.
        // `server/plugins/secure-cookies.ts` adds Secure on every https request.
        secure: false,
        sameSite: 'lax' as const,
      },
    },
    ocrServiceUrl: '',
    ocrDetModel: '',
    ocrRecModel: '',
    public: {
      appName: 'Yard Link',
      mapTilesUrl: '',
      mapSatelliteUrl: '',
      geocoderUrl: '',
      /**
       * Baked when the image is built, so More shows which bundle a phone is
       * actually running. A stale service worker is otherwise invisible.
       */
      buildTime: new Date().toISOString(),
    },
  },

  future: {
    compatibilityVersion: 4,
  },
  compatibilityDate: '2025-11-01',

  nitro: {
    preset: 'node-server',
    serverAssets: [{
      baseName: 'time-card-forms',
      dir: './server/assets/forms',
    }],
    hooks: {
      compiled(nitro) {
        const srcDir = join(nitro.options.rootDir, 'server/assets/forms')
        if (!existsSync(srcDir)) return
        const destDir = join(nitro.options.output.serverDir, 'assets/forms')
        mkdirSync(destDir, { recursive: true })
        for (const name of readdirSync(srcDir)) {
          cpSync(join(srcDir, name), join(destDir, name))
        }
      },
    },
    // Camera JPEGs are sent as data URLs (~1.3× the binary). 1 MB drops them.
    maxRequestBodySize: 20 * 1024 * 1024,
    // Do not set `externals.traceInclude: ['playwright']`. Nitro already
    // traces the dynamic `import('playwright')` from shipcsx-browser. That
    // option is file paths, so `'playwright'` becomes `/app/playwright` and
    // `nuxt build` fails in Docker. The runner installs Chromium afterwards.
  },

  vite: {
    plugins: [tailwindcss()],
    optimizeDeps: {
      include: ['pdfjs-dist'],
    },
  },

  typescript: {
    strict: true,
  },

  eslint: {
    config: {
      stylistic: true,
    },
  },

  pwa: {
    registerType: 'autoUpdate',
    manifest: {
      // Baked in at build time — the manifest is a static file, so changing the
      // env var afterwards requires a rebuild.
      name: process.env.NUXT_PUBLIC_APP_NAME || 'Yard Link',
      short_name: process.env.NUXT_PUBLIC_PWA_SHORT_NAME || 'Yard Link',
      description: process.env.NUXT_PUBLIC_PWA_DESCRIPTION || 'Yard Link — container and yard management',
      theme_color: '#052543',
      background_color: '#FFFFFF',
      display: 'standalone',
      orientation: 'portrait',
      start_url: '/',
      scope: '/',
      icons: [
        { src: '/icons/icon-192.png?v=3', sizes: '192x192', type: 'image/png', purpose: 'any' },
        { src: '/icons/icon-512.png?v=3', sizes: '512x512', type: 'image/png', purpose: 'any' },
        { src: '/icons/maskable-512.png?v=3', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
      ],
    },
    workbox: {
      // Operational API writes are never cached — the Phase 2 Dexie outbox owns replay.
      cacheId: 'yard-link-v2.0.0',
      navigateFallback: undefined,
      globPatterns: ['**/*.{js,css,html,svg,png,jpg,ico,woff2}'],
      navigateFallbackDenylist: [/^\/api\//],
    },
    client: {
      installPrompt: true,
    },
    devOptions: {
      enabled: false,
    },
  },
})
