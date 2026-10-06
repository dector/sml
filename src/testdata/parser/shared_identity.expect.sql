PRAGMA foreign_keys = ON;

CREATE TABLE "Identity Exact" (
  "Key Exact" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "shared" (
  "identity" INTEGER NOT NULL PRIMARY KEY REFERENCES "Identity Exact"("Key Exact") ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE "default_shared" (
  "identity" INTEGER NOT NULL PRIMARY KEY DEFAULT 7 REFERENCES "Identity Exact"("Key Exact") ON DELETE RESTRICT
) STRICT, WITHOUT ROWID;

CREATE TABLE "chain" (
  "identity" INTEGER NOT NULL PRIMARY KEY REFERENCES "shared"("identity") ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

CREATE TABLE "tuple" (
  "identity" INTEGER NOT NULL REFERENCES "Identity Exact"("Key Exact") ON DELETE RESTRICT,
  "part" INTEGER NOT NULL,
  PRIMARY KEY ("identity", "part")
) STRICT;

CREATE TABLE "text_identity" (
  "key" TEXT NOT NULL PRIMARY KEY
) STRICT;

CREATE TABLE "text_shared" (
  "identity" TEXT NOT NULL PRIMARY KEY DEFAULT 'seed' REFERENCES "text_identity"("key") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "text_required" (
  "identity" TEXT NOT NULL PRIMARY KEY REFERENCES "text_identity"("key") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "enum_identity" (
  "key" TEXT NOT NULL PRIMARY KEY CHECK ("key" IN ('ready', 'done'))
) STRICT;

CREATE TABLE "enum_shared" (
  "identity" TEXT NOT NULL PRIMARY KEY DEFAULT 'ready' CHECK ("identity" IN ('ready', 'done')) REFERENCES "enum_identity"("key") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "time_identity" (
  "key" TEXT NOT NULL PRIMARY KEY CHECK ("key" IS NULL OR (typeof("key") = 'text' AND length("key") = 20 AND instr("key", char(0)) = 0 AND "key" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("key", 1, 4) BETWEEN '0001' AND '9999' AND substr("key", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("key", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("key", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("key", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("key", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("key", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("key", 12, 2) BETWEEN '00' AND '23' AND substr("key", 15, 2) BETWEEN '00' AND '59' AND substr("key", 18, 2) BETWEEN '00' AND '59'))
) STRICT;

CREATE TABLE "time_shared" (
  "identity" TEXT NOT NULL PRIMARY KEY DEFAULT '2000-02-29T00:00:00Z' CHECK ("identity" IS NULL OR (typeof("identity") = 'text' AND length("identity") = 20 AND instr("identity", char(0)) = 0 AND "identity" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("identity", 1, 4) BETWEEN '0001' AND '9999' AND substr("identity", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("identity", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("identity", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("identity", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("identity", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("identity", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("identity", 12, 2) BETWEEN '00' AND '23' AND substr("identity", 15, 2) BETWEEN '00' AND '59' AND substr("identity", 18, 2) BETWEEN '00' AND '59')) REFERENCES "time_identity"("key") ON DELETE RESTRICT
) STRICT;
