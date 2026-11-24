-- What a receipt carries beyond the amounts, each in its own column instead
-- of being folded into the free-text notes.
ALTER TABLE "fuel_receipts" ADD COLUMN IF NOT EXISTS "station_address" text;
--> statement-breakpoint
ALTER TABLE "fuel_receipts" ADD COLUMN IF NOT EXISTS "invoice_number" text;
--> statement-breakpoint
ALTER TABLE "fuel_receipts" ADD COLUMN IF NOT EXISTS "fuel_type" text;
--> statement-breakpoint
ALTER TABLE "fuel_receipts" ADD COLUMN IF NOT EXISTS "card_last4" text;
--> statement-breakpoint
ALTER TABLE "fuel_receipts" ADD COLUMN IF NOT EXISTS "auth_code" text;
