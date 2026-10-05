PRAGMA foreign_keys = ON;

CREATE TABLE "unique values" (
  "exact code" TEXT DEFAULT 'default' CHECK (("exact code" != 'bad')) CONSTRAINT "code""constraint" UNIQUE,
  "number" INTEGER DEFAULT NULL UNIQUE,
  "flag" INTEGER CHECK ("flag" IN (0, 1)) UNIQUE,
  "created" TEXT CHECK ("created" IS NULL OR (typeof("created") = 'text' AND length("created") = 20 AND instr("created", char(0)) = 0 AND "created" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("created", 1, 4) BETWEEN '0001' AND '9999' AND substr("created", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("created", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("created", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("created", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("created", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("created", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("created", 12, 2) BETWEEN '00' AND '23' AND substr("created", 15, 2) BETWEEN '00' AND '59' AND substr("created", 18, 2) BETWEEN '00' AND '59')) UNIQUE,
  "choice" TEXT CHECK ("choice" IN ('a', 'b')) UNIQUE,
  "payload" BLOB UNIQUE,
  "ratio" REAL UNIQUE,
  "raw" TEXT DEFAULT ('raw') UNIQUE
) STRICT;
