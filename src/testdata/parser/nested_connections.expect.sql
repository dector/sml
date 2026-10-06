PRAGMA foreign_keys = ON;

-- Forward connection endpoints expand the whole target tuple.
CREATE TABLE "credit" (
  "authorship_author_id" INTEGER NOT NULL,
  "authorship_book_id" INTEGER NOT NULL,
  "organization_id" INTEGER NOT NULL REFERENCES "organization"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("authorship_author_id", "authorship_book_id", "organization_id"),
  FOREIGN KEY ("authorship_author_id", "authorship_book_id") REFERENCES "authorship" ("author_id", "book_id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "explicit_credit" (
  "pair_author_id" INTEGER NOT NULL,
  "pair_book_id" INTEGER NOT NULL,
  "organization_id" INTEGER NOT NULL REFERENCES "organization"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("pair_author_id", "pair_book_id", "organization_id"),
  FOREIGN KEY ("pair_author_id", "pair_book_id") REFERENCES "authorship" ("author_id", "book_id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "cascade_credit" (
  "authorship_author_id" INTEGER NOT NULL,
  "authorship_book_id" INTEGER NOT NULL,
  "organization_id" INTEGER NOT NULL REFERENCES "organization"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("authorship_author_id", "authorship_book_id", "organization_id"),
  FOREIGN KEY ("authorship_author_id", "authorship_book_id") REFERENCES "authorship" ("author_id", "book_id") ON DELETE CASCADE
) STRICT;

CREATE TABLE "tuple_cascade_credit" (
  "pair_author_id" INTEGER NOT NULL,
  "pair_book_id" INTEGER NOT NULL,
  "organization_id" INTEGER NOT NULL REFERENCES "organization"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("pair_author_id", "pair_book_id", "organization_id"),
  FOREIGN KEY ("pair_author_id", "pair_book_id") REFERENCES "authorship" ("author_id", "book_id") ON DELETE CASCADE
) STRICT;

CREATE TABLE "approval" (
  "credit_authorship_author_id" INTEGER NOT NULL,
  "credit_authorship_book_id" INTEGER NOT NULL,
  "credit_organization_id" INTEGER NOT NULL,
  "reviewer_id" INTEGER NOT NULL REFERENCES "reviewer"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("credit_authorship_author_id", "credit_authorship_book_id", "credit_organization_id", "reviewer_id"),
  FOREIGN KEY ("credit_authorship_author_id", "credit_authorship_book_id", "credit_organization_id") REFERENCES "credit" ("authorship_author_id", "authorship_book_id", "organization_id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "authorship__n__reviewer" (
  "authorship_author_id" INTEGER NOT NULL,
  "authorship_book_id" INTEGER NOT NULL,
  "reviewer_id" INTEGER NOT NULL REFERENCES "reviewer"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("authorship_author_id", "authorship_book_id", "reviewer_id"),
  FOREIGN KEY ("authorship_author_id", "authorship_book_id") REFERENCES "authorship" ("author_id", "book_id") ON DELETE RESTRICT
) STRICT;

CREATE TABLE "authorship" (
  "author_id" INTEGER NOT NULL REFERENCES "author"("id") ON DELETE RESTRICT,
  "book_id" INTEGER NOT NULL REFERENCES "book"("id") ON DELETE RESTRICT,
  PRIMARY KEY ("author_id", "book_id")
) STRICT;

CREATE TABLE "author" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "book" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "organization" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "reviewer" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE INDEX "credit_organization_id_idx" ON "credit" ("organization_id");

CREATE INDEX "explicit_credit_organization_id_idx" ON "explicit_credit" ("organization_id");

CREATE INDEX "cascade_credit_organization_id_idx" ON "cascade_credit" ("organization_id");

CREATE INDEX "tuple_cascade_credit_organization_id_idx" ON "tuple_cascade_credit" ("organization_id");

CREATE INDEX "approval_reviewer_id_idx" ON "approval" ("reviewer_id");

CREATE INDEX "authorship__n__reviewer_reviewer_id_idx" ON "authorship__n__reviewer" ("reviewer_id");

CREATE INDEX "authorship_book_id_idx" ON "authorship" ("book_id");
