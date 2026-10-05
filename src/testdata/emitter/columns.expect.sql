PRAGMA foreign_keys = ON;

CREATE TABLE "book" (
  "page_count" INTEGER NOT NULL,
  "price" REAL,
  "title" TEXT NOT NULL,
  "cover" BLOB
) STRICT;
