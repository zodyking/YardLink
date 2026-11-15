<script setup lang="ts">
import type { EmailSettingsForm } from '#shared/utils/email-settings'

/**
 * The outgoing email (SMTP) fields, shared by the setup wizard and Settings
 * so both ask for the same things in the same words.
 */
const form = defineModel<EmailSettingsForm>({ required: true })

defineProps<{
  errors?: Record<string, string>
  /** A password is already saved; leaving the field empty keeps it. */
  hasPassword?: boolean
  /** Shown as the suggested sender name. */
  companyName?: string
}>()
</script>

<template>
  <div class="settings-grid">
    <label class="field">
      <span>Mail server</span>
      <input
        v-model.trim="form.host"
        class="input mono"
        :class="{ invalid: errors?.host }"
        inputmode="url"
        autocapitalize="off"
        autocomplete="off"
        spellcheck="false"
        placeholder="smtp.yourprovider.com"
        maxlength="200"
      >
      <small class="field-hint">Your email provider calls this the SMTP server or host.</small>
      <small
        v-if="errors?.host"
        class="field-error"
      >{{ errors.host }}</small>
    </label>

    <label class="field">
      <span>Port</span>
      <input
        v-model="form.port"
        class="input mono"
        :class="{ invalid: errors?.port }"
        inputmode="numeric"
        autocomplete="off"
        placeholder="587"
        maxlength="5"
      >
      <small class="field-hint">Usually 587. Use 465 if your provider says SSL.</small>
      <small
        v-if="errors?.port"
        class="field-error"
      >{{ errors.port }}</small>
    </label>

    <label class="field">
      <span>User name</span>
      <input
        v-model.trim="form.user"
        class="input"
        autocapitalize="off"
        autocomplete="off"
        spellcheck="false"
        placeholder="dispatch@yourcompany.com"
        maxlength="200"
      >
      <small class="field-hint">Usually the full email address of the mailbox.</small>
    </label>

    <label class="field">
      <span>Password</span>
      <input
        v-model="form.password"
        class="input"
        type="password"
        autocomplete="new-password"
        :placeholder="hasPassword ? 'Saved. Leave empty to keep it' : ''"
        maxlength="500"
      >
      <small class="field-hint">Gmail and Outlook need an app password, not your normal one.</small>
    </label>

    <label class="field">
      <span>Sender name</span>
      <input
        v-model.trim="form.fromName"
        class="input"
        :placeholder="companyName || 'Your company name'"
        maxlength="120"
      >
      <small class="field-hint">The name people see in their inbox.</small>
    </label>

    <label class="field">
      <span>Sender address</span>
      <input
        v-model.trim="form.fromEmail"
        class="input"
        :class="{ invalid: errors?.fromEmail }"
        type="email"
        inputmode="email"
        autocapitalize="off"
        autocomplete="off"
        placeholder="Same as the user name"
        maxlength="200"
      >
      <small class="field-hint">Leave empty to send from the user name above.</small>
      <small
        v-if="errors?.fromEmail"
        class="field-error"
      >{{ errors.fromEmail }}</small>
    </label>
  </div>
</template>
