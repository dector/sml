PRAGMA foreign_keys = ON;

CREATE TABLE "owner" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "field_profile" (
  "owner" INTEGER UNIQUE REFERENCES "owner"("id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "table_profile" (
  "owner" INTEGER REFERENCES "owner"("id") ON DELETE RESTRICT,
  UNIQUE ("owner")
) STRICT;

CREATE TABLE "index_profile" (
  "owner" INTEGER REFERENCES "owner"("id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "shared_profile" (
  "owner" INTEGER NOT NULL PRIMARY KEY REFERENCES "owner"("id") ON DELETE RESTRICT
) STRICT, WITHOUT ROWID;

CREATE UNIQUE INDEX "index_profile_owner_idx" ON "index_profile" ("owner");
