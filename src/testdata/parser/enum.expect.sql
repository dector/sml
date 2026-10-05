PRAGMA foreign_keys = ON;

-- Exact enum text, not SQL.
CREATE TABLE "choice" (
  "key" TEXT NOT NULL PRIMARY KEY DEFAULT 'draft' CHECK ("key" IN ('draft', 'published', 'out-of-print')),
  "select" TEXT NOT NULL DEFAULT 'true' CHECK ("select" IN ('true', 'false', '_', 'a--b', '', 'null', 'it''s ready', 'tick`inside', 'hash`#inside', '雪😀', ('a' || char(0) || '雪'))),
  "optional" TEXT DEFAULT NULL CHECK ("optional" IN ('yes', 'no')),
  "nul" TEXT NOT NULL DEFAULT ('a' || char(0) || '雪') CHECK ("nul" IN (('a' || char(0) || '雪'), ''))
) STRICT;

CREATE TABLE "pair" (
  "first" TEXT NOT NULL DEFAULT 'A' CHECK ("first" IN ('A', 'B')),
  "second" TEXT NOT NULL DEFAULT 'x' CHECK ("second" IN ('x', 'y')),
  PRIMARY KEY ("first", "second")
) STRICT;
