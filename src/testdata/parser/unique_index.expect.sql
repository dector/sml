PRAGMA foreign_keys = ON;

CREATE TABLE "record store" (
  "first" INTEGER CONSTRAINT "first lookup" UNIQUE,
  "b" INTEGER,
  "c" INTEGER
) STRICT;

CREATE TABLE "pair" (
  "a" INTEGER,
  "b" INTEGER
) STRICT;

CREATE TABLE "other" (
  "value" INTEGER
) STRICT;

CREATE UNIQUE INDEX "first lookup" ON "record store" ("first");

CREATE INDEX "record store_b_idx" ON "record store" ("b");

CREATE UNIQUE INDEX "single b" ON "record store" ("b");

CREATE UNIQUE INDEX "pair lookup" ON "record store" ("c", "b");

CREATE INDEX "record store_c_b_idx" ON "record store" ("c", "b");

CREATE UNIQUE INDEX "pair_b_a_idx" ON "pair" ("b", "a");

CREATE UNIQUE INDEX "other_value_idx" ON "other" ("value");
