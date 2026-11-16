<script setup lang="ts">
/**
 * Line icons for menus and buttons, drawn in one weight on a 24-unit grid so
 * they sit evenly beside text. They take the text colour of whatever holds
 * them and are decorative: the label next to the icon carries the meaning.
 */
export type AppIconName
  = | 'board' | 'dispatch' | 'messages' | 'inventory' | 'drivers'
    | 'account' | 'company' | 'more' | 'import' | 'export' | 'menu' | 'signout'
    | 'documents' | 'send' | 'phone' | 'swap' | 'settings' | 'trash' | 'download'

withDefaults(defineProps<{ name: AppIconName, size?: number }>(), { size: 20 })
</script>

<template>
  <svg
    class="app-icon"
    viewBox="0 0 24 24"
    :width="size"
    :height="size"
    fill="none"
    stroke="currentColor"
    stroke-width="1.9"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    <!-- Board: a folded map with a pin -->
    <template v-if="name === 'board'">
      <path d="M9 4.5 3.5 6.5v13L9 17.5l6 2 5.5-2v-13L15 6.5z" />
      <path d="M9 4.5v13" />
      <path d="M15 6.5v13" />
    </template>

    <!-- Dispatch: a clipboard with checked lines -->
    <template v-else-if="name === 'dispatch'">
      <rect
        x="5"
        y="4.5"
        width="14"
        height="16"
        rx="2"
      />
      <path d="M9 4.5V3.5h6v1" />
      <path d="m8.5 10.5 1.4 1.4 2.4-2.6" />
      <path d="M14.5 10.8h1.5" />
      <path d="m8.5 15.3 1.4 1.4 2.4-2.6" />
      <path d="M14.5 15.6h1.5" />
    </template>

    <!-- Messages: a speech bubble -->
    <template v-else-if="name === 'messages'">
      <path d="M4 5.5h16v10.5H9.5L5 19.5V16H4z" />
      <path d="M8 9.5h8" />
      <path d="M8 12.5h5" />
    </template>

    <!-- Inventory: stacked containers -->
    <template v-else-if="name === 'inventory'">
      <rect
        x="3.5"
        y="4.5"
        width="17"
        height="6.5"
        rx="1.2"
      />
      <rect
        x="3.5"
        y="13"
        width="17"
        height="6.5"
        rx="1.2"
      />
      <path d="M8 6.8v2" />
      <path d="M12 6.8v2" />
      <path d="M16 6.8v2" />
      <path d="M8 15.3v2" />
      <path d="M12 15.3v2" />
      <path d="M16 15.3v2" />
    </template>

    <!-- Drivers: two people -->
    <template v-else-if="name === 'drivers'">
      <circle
        cx="9"
        cy="8.5"
        r="3.2"
      />
      <path d="M3.5 19.5c0-3 2.5-5 5.5-5s5.5 2 5.5 5" />
      <path d="M15.5 5.7a3.2 3.2 0 0 1 0 5.8" />
      <path d="M17.5 14.9c1.8.7 3 2.3 3 4.6" />
    </template>

    <!-- Account: one person in a circle -->
    <template v-else-if="name === 'account'">
      <circle
        cx="12"
        cy="12"
        r="8.5"
      />
      <circle
        cx="12"
        cy="10"
        r="2.8"
      />
      <path d="M6.8 18.2c1-2.2 2.9-3.4 5.2-3.4s4.2 1.2 5.2 3.4" />
    </template>

    <!-- Company: an office building -->
    <template v-else-if="name === 'company'">
      <path d="M5 20.5V5.5a1 1 0 0 1 1-1h8a1 1 0 0 1 1 1v15" />
      <path d="M15 10.5h3a1 1 0 0 1 1 1v9" />
      <path d="M3.5 20.5h17" />
      <path d="M8.5 8.5h3" />
      <path d="M8.5 12h3" />
      <path d="M8.5 15.5h3" />
    </template>

    <!-- More: three dots -->
    <template v-else-if="name === 'more'">
      <circle
        cx="5.5"
        cy="12"
        r="1.3"
      />
      <circle
        cx="12"
        cy="12"
        r="1.3"
      />
      <circle
        cx="18.5"
        cy="12"
        r="1.3"
      />
    </template>

    <!-- Import: arrow into a tray -->
    <template v-else-if="name === 'import' || name === 'download'">
      <path d="M12 4v11" />
      <path d="m7.5 10.5 4.5 4.5 4.5-4.5" />
      <path d="M4.5 16.5v2a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5v-2" />
    </template>

    <!-- Export: arrow out of a tray -->
    <template v-else-if="name === 'export'">
      <path d="M12 15V4" />
      <path d="m7.5 8.5 4.5-4.5 4.5 4.5" />
      <path d="M4.5 16.5v2a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5v-2" />
    </template>

    <template v-else-if="name === 'menu'">
      <path d="M4 7h16" />
      <path d="M4 12h16" />
      <path d="M4 17h16" />
    </template>

    <!-- Sign out: door with an arrow -->
    <template v-else-if="name === 'signout'">
      <path d="M10 4.5H6.5a1.5 1.5 0 0 0-1.5 1.5v12a1.5 1.5 0 0 0 1.5 1.5H10" />
      <path d="M10 12h10" />
      <path d="m16 8 4 4-4 4" />
    </template>

    <!-- Documents: a page with a folded corner -->
    <template v-else-if="name === 'documents'">
      <path d="M7 3.5h7l4 4v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-15a1 1 0 0 1 1-1z" />
      <path d="M14 3.5v4h4" />
      <path d="M9 12.5h6" />
      <path d="M9 16h6" />
    </template>

    <!-- Send: a paper plane -->
    <template v-else-if="name === 'send'">
      <path d="M20.5 3.5 3.5 10.5l6.5 3 3 6.5z" />
      <path d="m10 13.5 4.5-4.5" />
    </template>

    <template v-else-if="name === 'phone'">
      <path d="M6.5 3.5h3l1.5 4-2 1.5a11 11 0 0 0 6 6l1.5-2 4 1.5v3a2 2 0 0 1-2.2 2A16.5 16.5 0 0 1 4.5 5.7a2 2 0 0 1 2-2.2z" />
    </template>

    <!-- Swap: two arrows passing -->
    <template v-else-if="name === 'swap'">
      <path d="M4 8.5h14" />
      <path d="m14.5 5 3.5 3.5-3.5 3.5" />
      <path d="M20 15.5H6" />
      <path d="m9.5 12-3.5 3.5 3.5 3.5" />
    </template>

    <!-- Settings: sliders -->
    <template v-else-if="name === 'settings'">
      <path d="M4 7h9" />
      <path d="M17 7h3" />
      <circle
        cx="15"
        cy="7"
        r="2"
      />
      <path d="M4 17h3" />
      <path d="M11 17h9" />
      <circle
        cx="9"
        cy="17"
        r="2"
      />
    </template>

    <template v-else-if="name === 'trash'">
      <path d="M4.5 7h15" />
      <path d="M9.5 7V4.5h5V7" />
      <path d="M6.5 7l1 12.5h9l1-12.5" />
    </template>
  </svg>
</template>
