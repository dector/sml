PRAGMA foreign_keys = ON;

-- Owners table
CREATE TABLE "Owners" (
  -- Owner key
  "Key" INTEGER PRIMARY KEY AUTOINCREMENT,
  "label" TEXT NOT NULL
) STRICT;

CREATE TABLE "Items" (
  "note" TEXT NOT NULL,
  -- Stored owner
  "OwnerKey" INTEGER CONSTRAINT "one owner" UNIQUE REFERENCES "Owners"("Key") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "Nodes" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  -- Stored parent
  "parent" INTEGER CONSTRAINT "one parent" UNIQUE REFERENCES "Nodes"("id") ON DELETE RESTRICT
) STRICT;
