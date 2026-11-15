ALTER TABLE "users" ADD COLUMN "email_prefs" jsonb DEFAULT '{}'::jsonb NOT NULL;
