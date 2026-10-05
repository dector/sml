PRAGMA foreign_keys = ON;

CREATE TABLE "entry" (
  "tenant""id" INTEGER NOT NULL,
  "value" TEXT NOT NULL,
  "select" TEXT NOT NULL,
  PRIMARY KEY ("tenant""id", "select")
) STRICT;
