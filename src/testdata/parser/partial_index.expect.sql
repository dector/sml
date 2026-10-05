PRAGMA foreign_keys = ON;

CREATE TABLE "record store" (
  "email" TEXT,
  "deleted at" INTEGER,
  "active" INTEGER NOT NULL CHECK ("active" IN (0, 1)),
  "low" INTEGER NOT NULL,
  "high" INTEGER NOT NULL
) STRICT;

CREATE INDEX "boolean lookup" ON "record store" ("email") WHERE (("active" AND ("low" < "high")));

CREATE UNIQUE INDEX "active email" ON "record store" ("email") WHERE ("deleted at" IS NULL);

CREATE INDEX "raw lookup" ON "record store" ("low", "high") WHERE ("deleted at" IS NULL AND "low" < "high");
