PRAGMA foreign_keys = ON;

CREATE TABLE "pairs" (
  "key_a" INTEGER NOT NULL,
  "key_b" INTEGER NOT NULL,
  "left value" TEXT CHECK (("left value" != '')),
  "right""value" TEXT,
  "flag" INTEGER CHECK ("flag" IN (0, 1)),
  PRIMARY KEY ("key_a", "key_b"),
  CHECK (("key_a" > 0)),
  CONSTRAINT "pair""constraint" UNIQUE ("right""value", "left value"),
  UNIQUE ("flag")
) STRICT;

CREATE TABLE "other" (
  "a" INTEGER NOT NULL,
  "b" INTEGER NOT NULL,
  UNIQUE ("a", "b")
) STRICT;
