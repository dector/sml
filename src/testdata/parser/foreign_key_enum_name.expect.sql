PRAGMA foreign_keys = ON;

CREATE TABLE "child" (
  "bare" TEXT NOT NULL DEFAULT 'ready' CHECK ("bare" IN ('ready', 'it''s ready')) REFERENCES "Enum Exact"("Enum Key") ON DELETE RESTRICT,
  "quoted" TEXT NOT NULL DEFAULT 'it''s ready' CHECK ("quoted" IN ('ready', 'it''s ready')) REFERENCES "Enum Exact"("Enum Key") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "Enum Exact" (
  "Enum Key" TEXT NOT NULL PRIMARY KEY CHECK ("Enum Key" IN ('ready', 'it''s ready'))
) STRICT;

CREATE INDEX "child_bare_idx" ON "child" ("bare");

CREATE INDEX "child_quoted_idx" ON "child" ("quoted");
