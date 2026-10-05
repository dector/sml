PRAGMA foreign_keys = ON;

-- Public author.
--  Keep this extra space.
CREATE TABLE "author" (
  -- Display name.
  "display`name" TEXT NOT NULL,
  -- A numeric value.
  "score" REAL NOT NULL DEFAULT -1.25
) STRICT;
