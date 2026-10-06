PRAGMA foreign_keys = ON;

CREATE TABLE "named ranges" (
  "low value" INTEGER CONSTRAINT "nonnegative `lower`" CHECK ((("low value" >= 0))) CHECK ((("low value" IS NOT NULL) OR ("low value" IS NULL))),
  "upper" INTEGER CONSTRAINT "upper ` limit" CHECK (("upper" IS NULL OR "upper" < 100)),
  CONSTRAINT "range ""order""" CHECK ((("low value" <= "upper"))),
  CONSTRAINT "upper required" CHECK ((("low value" IS NULL) OR ("upper" IS NOT NULL)))
) STRICT;

CREATE TABLE "flags" (
  "enabled" INTEGER CHECK ("enabled" IN (0, 1)) CONSTRAINT "enabled only" CHECK (("enabled" != 0))
) STRICT;

CREATE TABLE "safe" (
  "n" INTEGER NOT NULL CONSTRAINT "safe""); DROP TABLE flags; --" CHECK (("n" > 0))
) STRICT;
