PRAGMA foreign_keys = ON;

-- Generated pairs use header order even when the marker is last.
CREATE TABLE "pair" (
  "writer_account_key" INTEGER NOT NULL REFERENCES "Author Exact"("Actual Key") ON DELETE RESTRICT,
  "snake_name_account_key" TEXT NOT NULL REFERENCES "snake_name"("account_key") ON DELETE RESTRICT,
  "amount" INTEGER NOT NULL DEFAULT 2,
  "cleanup" INTEGER REFERENCES "Author Exact"("Actual Key") ON DELETE CASCADE,
  PRIMARY KEY ("writer_account_key", "snake_name_account_key")
) STRICT;

CREATE TABLE "trio" (
  "left_account_key" INTEGER NOT NULL REFERENCES "Author Exact"("Actual Key") ON DELETE RESTRICT,
  "right_account_key" INTEGER NOT NULL REFERENCES "Author Exact"("Actual Key") ON DELETE RESTRICT,
  "context_account_key" INTEGER NOT NULL REFERENCES "Author Exact"("Actual Key") ON DELETE RESTRICT,
  "label" TEXT NOT NULL DEFAULT 'ready',
  PRIMARY KEY ("left_account_key", "right_account_key", "context_account_key")
) STRICT;

CREATE TABLE "kinds" (
  "state_state_key" TEXT NOT NULL CHECK ("state_state_key" IN ('ready', 'done')) REFERENCES "state"("state_key") ON DELETE RESTRICT,
  "clock_moment" TEXT NOT NULL CHECK ("clock_moment" IS NULL OR (typeof("clock_moment") = 'text' AND length("clock_moment") = 20 AND instr("clock_moment", char(0)) = 0 AND "clock_moment" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("clock_moment", 1, 4) BETWEEN '0001' AND '9999' AND substr("clock_moment", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("clock_moment", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("clock_moment", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("clock_moment", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("clock_moment", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("clock_moment", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("clock_moment", 12, 2) BETWEEN '00' AND '23' AND substr("clock_moment", 15, 2) BETWEEN '00' AND '59' AND substr("clock_moment", 18, 2) BETWEEN '00' AND '59')) REFERENCES "clock"("moment") ON DELETE RESTRICT,
  "alias_external_key" INTEGER NOT NULL REFERENCES "alias"("external_key") ON DELETE RESTRICT,
  PRIMARY KEY ("state_state_key", "clock_moment", "alias_external_key")
) STRICT;

CREATE TABLE "Author Exact" (
  "Actual Key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "snake_name" (
  "account_key" TEXT NOT NULL PRIMARY KEY
) STRICT;

CREATE TABLE "state" (
  "state_key" TEXT NOT NULL PRIMARY KEY DEFAULT 'ready' CHECK ("state_key" IN ('ready', 'done'))
) STRICT;

CREATE TABLE "clock" (
  "moment" TEXT NOT NULL PRIMARY KEY CHECK ("moment" IS NULL OR (typeof("moment") = 'text' AND length("moment") = 20 AND instr("moment", char(0)) = 0 AND "moment" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("moment", 1, 4) BETWEEN '0001' AND '9999' AND substr("moment", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("moment", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("moment", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("moment", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("moment", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("moment", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("moment", 12, 2) BETWEEN '00' AND '23' AND substr("moment", 15, 2) BETWEEN '00' AND '59' AND substr("moment", 18, 2) BETWEEN '00' AND '59'))
) STRICT;

CREATE TABLE "alias" (
  "external_key" INTEGER NOT NULL PRIMARY KEY REFERENCES "Author Exact"("Actual Key") ON DELETE RESTRICT
) STRICT, WITHOUT ROWID;

CREATE INDEX "pair_snake_name_account_key_idx" ON "pair" ("snake_name_account_key");

CREATE INDEX "pair_cleanup_idx" ON "pair" ("cleanup");

CREATE INDEX "trio_right_account_key_idx" ON "trio" ("right_account_key");

CREATE INDEX "trio_context_account_key_idx" ON "trio" ("context_account_key");

CREATE INDEX "kinds_clock_moment_idx" ON "kinds" ("clock_moment");

CREATE INDEX "kinds_alias_external_key_idx" ON "kinds" ("alias_external_key");
