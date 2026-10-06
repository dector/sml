PRAGMA foreign_keys = ON;

CREATE TABLE "reader" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "book" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "following" (
  "left_reader" INTEGER NOT NULL REFERENCES "reader"("id") ON DELETE RESTRICT,
  "right_reader" INTEGER NOT NULL REFERENCES "reader"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("left_reader", "right_reader")
) STRICT;

CREATE TABLE "trio" (
  "first" INTEGER NOT NULL REFERENCES "reader"("id") ON DELETE RESTRICT,
  "second" INTEGER NOT NULL REFERENCES "reader"("id") ON DELETE RESTRICT,
  "third" INTEGER NOT NULL REFERENCES "reader"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("first", "second", "third")
) STRICT;

CREATE TABLE "single" (
  "reader" INTEGER NOT NULL UNIQUE REFERENCES "reader"("id") ON DELETE RESTRICT,
  "book" INTEGER NOT NULL REFERENCES "book"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("reader", "book")
) STRICT;

CREATE INDEX "following_right_reader_idx" ON "following" ("right_reader");

CREATE INDEX "trio_second_idx" ON "trio" ("second");

CREATE INDEX "trio_third_idx" ON "trio" ("third");

CREATE INDEX "single_book_idx" ON "single" ("book");
