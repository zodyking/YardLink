CREATE TYPE "public"."duty_cycle_status" AS ENUM('ACTIVE', 'COMPLETED', 'VOIDED');
--> statement-breakpoint
CREATE TYPE "public"."message_thread_kind" AS ENUM('DISPATCH', 'DIRECT');
--> statement-breakpoint
CREATE TABLE "container_duty_cycles" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"company_id" uuid NOT NULL,
	"container_id" uuid NOT NULL,
	"sequence" integer NOT NULL,
	"status" "duty_cycle_status" DEFAULT 'ACTIVE' NOT NULL,
	"started_at" timestamp with time zone NOT NULL,
	"start_event_id" uuid,
	"start_location_id" uuid,
	"start_trip_id" uuid,
	"start_driver_id" uuid,
	"completed_at" timestamp with time zone,
	"end_event_id" uuid,
	"end_location_id" uuid,
	"end_trip_id" uuid,
	"end_driver_id" uuid,
	"closed_by_next_pickup" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "container_duty_cycles" ADD CONSTRAINT "container_duty_cycles_company_id_companies_id_fk" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "container_duty_cycles" ADD CONSTRAINT "container_duty_cycles_container_id_containers_id_fk" FOREIGN KEY ("container_id") REFERENCES "public"."containers"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "container_duty_cycles_sequence_key" ON "container_duty_cycles" USING btree ("container_id","sequence");
--> statement-breakpoint
CREATE UNIQUE INDEX "container_duty_cycles_one_active" ON "container_duty_cycles" USING btree ("container_id") WHERE status = 'ACTIVE';
--> statement-breakpoint
CREATE INDEX "container_duty_cycles_company_idx" ON "container_duty_cycles" USING btree ("company_id","status");
--> statement-breakpoint
ALTER TABLE "trips" ADD COLUMN "duty_cycle_id" uuid;
--> statement-breakpoint
ALTER TABLE "container_events" ADD COLUMN "duty_cycle_id" uuid;
--> statement-breakpoint
CREATE INDEX "container_events_chassis_idx" ON "container_events" USING btree ("chassis_id","occurred_at");
--> statement-breakpoint
CREATE INDEX "container_events_cycle_idx" ON "container_events" USING btree ("duty_cycle_id");
--> statement-breakpoint
CREATE TABLE "message_threads" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"company_id" uuid NOT NULL,
	"kind" "message_thread_kind" NOT NULL,
	"driver_user_id" uuid,
	"user_low_id" uuid,
	"user_high_id" uuid,
	"last_message_at" timestamp with time zone,
	"last_message_preview" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "message_threads" ADD CONSTRAINT "message_threads_company_id_companies_id_fk" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "message_threads" ADD CONSTRAINT "message_threads_driver_user_id_users_id_fk" FOREIGN KEY ("driver_user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "message_threads" ADD CONSTRAINT "message_threads_user_low_id_users_id_fk" FOREIGN KEY ("user_low_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "message_threads" ADD CONSTRAINT "message_threads_user_high_id_users_id_fk" FOREIGN KEY ("user_high_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "message_threads_dispatch_key" ON "message_threads" USING btree ("company_id","driver_user_id") WHERE kind = 'DISPATCH';
--> statement-breakpoint
CREATE UNIQUE INDEX "message_threads_direct_key" ON "message_threads" USING btree ("company_id","user_low_id","user_high_id") WHERE kind = 'DIRECT';
--> statement-breakpoint
CREATE INDEX "message_threads_company_idx" ON "message_threads" USING btree ("company_id","last_message_at");
--> statement-breakpoint
CREATE TABLE "messages" (
	"id" uuid PRIMARY KEY NOT NULL,
	"company_id" uuid NOT NULL,
	"thread_id" uuid NOT NULL,
	"sender_user_id" uuid,
	"sender_name" text NOT NULL,
	"body" text NOT NULL,
	"kind" text DEFAULT 'TEXT' NOT NULL,
	"trip_id" uuid,
	"document_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_company_id_companies_id_fk" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_thread_id_message_threads_id_fk" FOREIGN KEY ("thread_id") REFERENCES "public"."message_threads"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "messages" ADD CONSTRAINT "messages_sender_user_id_users_id_fk" FOREIGN KEY ("sender_user_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
CREATE INDEX "messages_thread_idx" ON "messages" USING btree ("thread_id","created_at");
--> statement-breakpoint
CREATE TABLE "message_reads" (
	"thread_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"last_read_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "message_reads" ADD CONSTRAINT "message_reads_thread_id_message_threads_id_fk" FOREIGN KEY ("thread_id") REFERENCES "public"."message_threads"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "message_reads" ADD CONSTRAINT "message_reads_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "message_reads_key" ON "message_reads" USING btree ("thread_id","user_id");
--> statement-breakpoint
UPDATE "users" SET "email_verified_at" = now() WHERE "email_verified_at" IS NULL;
