PRAGMA foreign_keys = ON;

CREATE TABLE "record"" store" (
  "first" TEXT NOT NULL CHECK (("first" != '')),
  "second value" INTEGER NOT NULL,
  CONSTRAINT "alternate" UNIQUE ("first")
) STRICT;

CREATE TABLE "other" (
  "value" INTEGER NOT NULL
) STRICT;

CREATE INDEX "first"" lookup" ON "record"" store" ("first");

CREATE INDEX "record"" store_first_idx" ON "record"" store" ("first");

CREATE INDEX "record"" store_second value_idx" ON "record"" store" ("second value");

CREATE INDEX "record"" store_second value_first_idx" ON "record"" store" ("second value", "first");

CREATE INDEX "alternate" ON "record"" store" ("second value", "first");

CREATE INDEX "other_value_idx" ON "other" ("value");
