PRAGMA foreign_keys = ON;

CREATE TABLE "Library Links" (
  "author_id" INTEGER NOT NULL REFERENCES "Writer"("id") ON DELETE RESTRICT,
  "volume" INTEGER NOT NULL REFERENCES "book"("id") ON DELETE RESTRICT,
  "note" TEXT NOT NULL DEFAULT 'ready',
  PRIMARY KEY ("author_id", "volume")
) STRICT;

CREATE TABLE "Writer" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "book" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE INDEX "Library Links_volume_idx" ON "Library Links" ("volume");
