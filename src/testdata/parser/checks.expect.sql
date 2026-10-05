PRAGMA foreign_keys = ON;

CREATE TABLE "samples" (
  "opt""value" INTEGER CHECK (("opt""value" > 0)) CHECK (("opt""value" < 10)),
  "required" INTEGER NOT NULL CHECK (((("required" >= 0) AND ("required" <= 10)))),
  "present" INTEGER CHECK (("present" IS NOT (NULL))),
  "flag" INTEGER CHECK ("flag" IN (0, 1)) CHECK ("flag") CHECK (("flag" = 1)),
  "state" TEXT DEFAULT 'ready' CHECK ("state" IN ('ready', 'done')) CHECK (("state" != 'done')),
  "created" TEXT CHECK ("created" IS NULL OR (typeof("created") = 'text' AND length("created") = 20 AND instr("created", char(0)) = 0 AND "created" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("created", 1, 4) BETWEEN '0001' AND '9999' AND substr("created", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("created", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("created", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("created", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("created", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("created", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("created", 12, 2) BETWEEN '00' AND '23' AND substr("created", 15, 2) BETWEEN '00' AND '59' AND substr("created", 18, 2) BETWEEN '00' AND '59')) CHECK (("created" >= '2000-01-01T00:00:00Z')),
  "other" INTEGER NOT NULL CHECK ((other >= required)),
  "label" TEXT NOT NULL CHECK (("label" != 'bad')) CHECK (("label" != 'no')),
  "empty" TEXT NOT NULL
) STRICT;
