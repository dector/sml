PRAGMA foreign_keys = ON;

-- People with real keys.
CREATE TABLE "People Exact" (
  "Person Key" REAL NOT NULL PRIMARY KEY
) STRICT;

CREATE TABLE "Books Exact" (
  "Book Key" TEXT NOT NULL PRIMARY KEY
) STRICT;

-- Explicit stored borrow tuples.
CREATE TABLE "Borrow Exact" (
  "Book Ref" TEXT NOT NULL REFERENCES "Books Exact"("Book Key") ON DELETE RESTRICT,
  -- Extra value documentation.
  "amount" INTEGER NOT NULL DEFAULT 2 CHECK (("amount" > 0)),
  "Person Ref" REAL NOT NULL REFERENCES "People Exact"("Person Key") ON DELETE CASCADE,
  "state" TEXT NOT NULL DEFAULT 'ready' CHECK ("state" IN ('ready', 'done')),
  "created_at" TEXT NOT NULL DEFAULT '2000-02-29T00:00:00Z' CHECK ("created_at" IS NULL OR (typeof("created_at") = 'text' AND length("created_at") = 20 AND instr("created_at", char(0)) = 0 AND "created_at" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("created_at", 1, 4) BETWEEN '0001' AND '9999' AND substr("created_at", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("created_at", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("created_at", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("created_at", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("created_at", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("created_at", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("created_at", 12, 2) BETWEEN '00' AND '23' AND substr("created_at", 15, 2) BETWEEN '00' AND '59' AND substr("created_at", 18, 2) BETWEEN '00' AND '59')),
  "tag" TEXT NOT NULL UNIQUE,
  PRIMARY KEY ("Book Ref", "Person Ref"),
  CHECK (("amount" < 10))
) STRICT;

-- Three-role stored tuples.
CREATE TABLE "Triple Exact" (
  "Context Ref" REAL NOT NULL REFERENCES "People Exact"("Person Key") ON DELETE RESTRICT,
  "note" TEXT NOT NULL DEFAULT 'seed',
  "Destination Ref" REAL NOT NULL REFERENCES "People Exact"("Person Key") ON DELETE RESTRICT,
  "Origin Ref" REAL NOT NULL REFERENCES "People Exact"("Person Key") ON DELETE RESTRICT,
  PRIMARY KEY ("Context Ref", "Destination Ref", "Origin Ref")
) STRICT;

CREATE INDEX "State Lookup" ON "Borrow Exact" ("state");

CREATE INDEX "Borrow Exact_Person Ref_idx" ON "Borrow Exact" ("Person Ref");

CREATE INDEX "Triple Exact_Destination Ref_idx" ON "Triple Exact" ("Destination Ref");

CREATE INDEX "Triple Exact_Origin Ref_idx" ON "Triple Exact" ("Origin Ref");
