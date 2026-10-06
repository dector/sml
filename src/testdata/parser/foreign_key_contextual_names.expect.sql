PRAGMA foreign_keys = ON;

CREATE TABLE "child" (
  "parent" INTEGER NOT NULL DEFAULT 1 REFERENCES "Enum Exact"("Integer Key") ON DELETE RESTRICT,
  "clock" INTEGER NOT NULL DEFAULT 2 REFERENCES "Datetime Exact"("key") ON DELETE RESTRICT,
  "choice" TEXT NOT NULL DEFAULT 'it''s ready' CHECK ("choice" IN ('it''s ready', 'done')) REFERENCES "Str Exact"("key") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "Enum Exact" (
  "Integer Key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "Datetime Exact" (
  "key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "Str Exact" (
  "key" TEXT NOT NULL PRIMARY KEY CHECK ("key" IN ('it''s ready', 'done'))
) STRICT;

CREATE INDEX "child_parent_idx" ON "child" ("parent");

CREATE INDEX "child_clock_idx" ON "child" ("clock");

CREATE INDEX "child_choice_idx" ON "child" ("choice");
