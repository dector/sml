PRAGMA foreign_keys = ON;

CREATE TABLE "ranges" (
  "group_id" INTEGER NOT NULL,
  "entry_id" INTEGER NOT NULL,
  "low""value" INTEGER CHECK (("low""value" >= 0)),
  "high value" INTEGER,
  PRIMARY KEY ("group_id", "entry_id"),
  CHECK (("low""value" <= "high value")),
  CHECK ((("low""value" IS NULL) OR ("high value" IS NOT NULL))),
  CHECK (("high value" < 100))
) STRICT;

CREATE TABLE "flags" (
  "enabled" INTEGER CHECK ("enabled" IN (0, 1)),
  CHECK ("enabled")
) STRICT;

CREATE TABLE "times" (
  "start" TEXT CHECK ("start" IS NULL OR (typeof("start") = 'text' AND length("start") = 20 AND instr("start", char(0)) = 0 AND "start" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("start", 1, 4) BETWEEN '0001' AND '9999' AND substr("start", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("start", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("start", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("start", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("start", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("start", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("start", 12, 2) BETWEEN '00' AND '23' AND substr("start", 15, 2) BETWEEN '00' AND '59' AND substr("start", 18, 2) BETWEEN '00' AND '59')),
  "finish" TEXT CHECK ("finish" IS NULL OR (typeof("finish") = 'text' AND length("finish") = 20 AND instr("finish", char(0)) = 0 AND "finish" GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' AND substr("finish", 1, 4) BETWEEN '0001' AND '9999' AND substr("finish", 6, 2) BETWEEN '01' AND '12' AND CAST(substr("finish", 9, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr("finish", 6, 2) AS INTEGER) WHEN 2 THEN 28 + (CAST(substr("finish", 1, 4) AS INTEGER) % 4 = 0 AND (CAST(substr("finish", 1, 4) AS INTEGER) % 100 != 0 OR CAST(substr("finish", 1, 4) AS INTEGER) % 400 = 0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END AND substr("finish", 12, 2) BETWEEN '00' AND '23' AND substr("finish", 15, 2) BETWEEN '00' AND '59' AND substr("finish", 18, 2) BETWEEN '00' AND '59')),
  CHECK (("finish" >= "start"))
) STRICT;
