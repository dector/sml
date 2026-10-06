PRAGMA foreign_keys = ON;

CREATE TABLE "child" (
  "Owner Exact" INTEGER DEFAULT 7 CHECK (("Owner Exact" > 0)) UNIQUE REFERENCES "Parent Exact"("Key Exact") ON DELETE RESTRICT,
  "label" TEXT DEFAULT 'seed' REFERENCES "label"("key") ON DELETE RESTRICT,
  "state" TEXT DEFAULT 'ready' CHECK ("state" IN ('ready', 'done')) REFERENCES "state"("key") ON DELETE RESTRICT,
  "stamp" TEXT DEFAULT '2000-02-29T00:00:00Z' CHECK ("stamp" IS NULL OR (typeof("stamp") = 'text' AND length("stamp") = 20 AND instr("stamp", char(0)) = 0 AND "stamp" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("stamp", 1, 4) BETWEEN '0001' AND '9999' AND substr("stamp", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("stamp", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("stamp", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("stamp", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("stamp", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("stamp", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("stamp", 12, 2) BETWEEN '00' AND '23' AND substr("stamp", 15, 2) BETWEEN '00' AND '59' AND substr("stamp", 18, 2) BETWEEN '00' AND '59')) REFERENCES "clock"("key") ON DELETE RESTRICT,
  CHECK (("Owner Exact" > 0))
) STRICT;

CREATE TABLE "Parent Exact" (
  "Key Exact" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "label" (
  "key" TEXT NOT NULL PRIMARY KEY
) STRICT;

CREATE TABLE "state" (
  "key" TEXT NOT NULL PRIMARY KEY CHECK ("key" IN ('ready', 'done'))
) STRICT;

CREATE TABLE "clock" (
  "key" TEXT NOT NULL PRIMARY KEY CHECK ("key" IS NULL OR (typeof("key") = 'text' AND length("key") = 20 AND instr("key", char(0)) = 0 AND "key" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("key", 1, 4) BETWEEN '0001' AND '9999' AND substr("key", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("key", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("key", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("key", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("key", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("key", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("key", 12, 2) BETWEEN '00' AND '23' AND substr("key", 15, 2) BETWEEN '00' AND '59' AND substr("key", 18, 2) BETWEEN '00' AND '59'))
) STRICT;

CREATE TABLE "node" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "parent" INTEGER REFERENCES "node"("id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "left" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "right" INTEGER REFERENCES "right"("id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "right" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "left" INTEGER REFERENCES "left"("id") ON DELETE RESTRICT
) STRICT;

CREATE INDEX "child_label_idx" ON "child" ("label");
