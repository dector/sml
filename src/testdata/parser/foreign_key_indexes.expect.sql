PRAGMA foreign_keys = ON;

CREATE TABLE "child" (
  "first" INTEGER NOT NULL REFERENCES "parent"("id") ON DELETE RESTRICT,
  "second" INTEGER NOT NULL REFERENCES "parent"("id") ON DELETE RESTRICT,
  "native" INTEGER UNIQUE REFERENCES "parent"("id") ON DELETE RESTRICT,
  "composite" INTEGER REFERENCES "parent"("id") ON DELETE RESTRICT,
  "tail" INTEGER REFERENCES "parent"("id") ON DELETE RESTRICT,
  "ordinary" INTEGER REFERENCES "parent"("id") ON DELETE RESTRICT,
  "unique_index" INTEGER REFERENCES "parent"("id") ON DELETE RESTRICT,
  "partial" INTEGER REFERENCES "parent"("id") ON DELETE RESTRICT,
  "partial_unique" INTEGER REFERENCES "parent"("id") ON DELETE RESTRICT,
  "truth" INTEGER REFERENCES "parent"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("first", "second"),
  UNIQUE ("composite", "tail")
) STRICT;

CREATE TABLE "parent" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "shared" (
  "id" INTEGER NOT NULL PRIMARY KEY REFERENCES "parent"("id") ON DELETE RESTRICT
) STRICT, WITHOUT ROWID;

CREATE TABLE "rowid" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "parent" INTEGER UNIQUE REFERENCES "parent"("id") ON DELETE RESTRICT
) STRICT;

CREATE INDEX "child_tail_second_idx" ON "child" ("tail", "second");

CREATE INDEX "child_ordinary_tail_idx" ON "child" ("ordinary", "tail");

CREATE UNIQUE INDEX "child_unique_index_tail_idx" ON "child" ("unique_index", "tail");

CREATE INDEX "partial lookup" ON "child" ("partial") WHERE (partial IS NOT NULL);

CREATE UNIQUE INDEX "partial unique lookup" ON "child" ("partial_unique") WHERE ("partial_unique" IS NOT NULL);

CREATE INDEX "true lookup" ON "child" ("truth") WHERE 1;

CREATE INDEX "child_second_idx" ON "child" ("second");

CREATE INDEX "child_partial_idx" ON "child" ("partial");

CREATE INDEX "child_partial_unique_idx" ON "child" ("partial_unique");

CREATE INDEX "child_truth_idx" ON "child" ("truth");
