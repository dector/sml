PRAGMA foreign_keys = ON;

CREATE TABLE "settings" (
  "count" INTEGER NOT NULL DEFAULT -7,
  "ratio" REAL NOT NULL DEFAULT 1.25,
  "whole" REAL NOT NULL DEFAULT 2,
  "label" TEXT NOT NULL DEFAULT 'It''s ready',
  "empty_text" TEXT NOT NULL DEFAULT '',
  "payload" BLOB NOT NULL DEFAULT X'00FF27',
  "empty_blob" BLOB NOT NULL DEFAULT X'',
  "optional" TEXT DEFAULT NULL,
  "created_at" TEXT NOT NULL DEFAULT (strftime('%Y', 'now')),
  "nul_text" TEXT NOT NULL DEFAULT ('a' || char(0) || 'b'),
  "no_default" INTEGER NOT NULL
) STRICT;

CREATE TABLE "code" (
  "key" TEXT NOT NULL PRIMARY KEY DEFAULT 'initial'
) STRICT;

CREATE TABLE "pair" (
  "first" INTEGER NOT NULL DEFAULT 1,
  "second" INTEGER NOT NULL DEFAULT 2,
  PRIMARY KEY ("first", "second")
) STRICT;
