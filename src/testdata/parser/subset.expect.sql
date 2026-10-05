PRAGMA foreign_keys = ON;

CREATE TABLE "http_server" (
  "id" INTEGER PRIMARY KEY,
  "url_value" TEXT NOT NULL DEFAULT 'It''s C:\books',
  "raw_text" TEXT NOT NULL DEFAULT 'This contains ''# and \ literally',
  "ratio" REAL NOT NULL DEFAULT 1.25,
  "whole" REAL NOT NULL DEFAULT 2,
  "payload" BLOB NOT NULL DEFAULT (X'00FF'),
  "optional" TEXT DEFAULT NULL,
  "Writer""ID" INTEGER NOT NULL DEFAULT -7
) STRICT;

CREATE TABLE "Exact Table" (
  "value" BLOB NOT NULL
) STRICT;
