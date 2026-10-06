PRAGMA foreign_keys = ON;

CREATE TABLE "pair" (
  -- The writer override keeps its own docs.
  "writer_id" INTEGER NOT NULL DEFAULT 1 CHECK (("writer_id" > 0)) REFERENCES "author"("Actual Key") ON DELETE CASCADE,
  "status" TEXT NOT NULL DEFAULT 'ready' CHECK ("status" IN ('ready', 'done')) UNIQUE REFERENCES "state"("code") ON DELETE RESTRICT,
  "amount" INTEGER NOT NULL DEFAULT 2,
  "note" TEXT NOT NULL DEFAULT 'unchanged',
  PRIMARY KEY ("writer_id", "status")
) STRICT;

CREATE TABLE "self" (
  "first_id" INTEGER NOT NULL REFERENCES "author"("Actual Key") ON DELETE RESTRICT,
  "right_id" INTEGER NOT NULL REFERENCES "author"("Actual Key") ON DELETE RESTRICT,
  "context_id" INTEGER NOT NULL DEFAULT 3 REFERENCES "author"("Actual Key") ON DELETE RESTRICT,
  "label" TEXT NOT NULL DEFAULT 'ready',
  PRIMARY KEY ("first_id", "right_id", "context_id")
) STRICT;

CREATE TABLE "author" (
  "Actual Key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "state" (
  "code" TEXT NOT NULL PRIMARY KEY CHECK ("code" IN ('ready', 'done'))
) STRICT;

CREATE INDEX "pair_writer_id_status_idx" ON "pair" ("writer_id", "status");

CREATE INDEX "self_right_id_first_id_idx" ON "self" ("right_id", "first_id");

CREATE INDEX "self_context_id_idx" ON "self" ("context_id");
