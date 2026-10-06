PRAGMA foreign_keys = ON;

CREATE TABLE "writers" (
  "writer_key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "book" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "author__n__book" (
  "author_id" INTEGER NOT NULL REFERENCES "writers"("writer_key") ON DELETE RESTRICT,
  "book_id" INTEGER NOT NULL REFERENCES "book"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("author_id", "book_id")
) STRICT;

CREATE INDEX "author__n__book_book_id_idx" ON "author__n__book" ("book_id");
