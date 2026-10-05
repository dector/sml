PRAGMA foreign_keys = ON;

CREATE TABLE "flags" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("enabled" IN (0, 1)),
  "disabled" INTEGER NOT NULL DEFAULT 0 CHECK ("disabled" IN (0, 1)),
  "optional" INTEGER CHECK ("optional" IN (0, 1)),
  "unknown" INTEGER DEFAULT NULL CHECK ("unknown" IN (0, 1)),
  "a""b`c" INTEGER NOT NULL DEFAULT (1 = 1) CHECK ("a""b`c" IN (0, 1))
) STRICT;
