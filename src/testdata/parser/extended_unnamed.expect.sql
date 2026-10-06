PRAGMA foreign_keys = ON;

CREATE TABLE "a__n__b__n__c" (
  "a_key" INTEGER NOT NULL DEFAULT 1 REFERENCES "Parent"("key") ON DELETE CASCADE,
  "b_key" INTEGER NOT NULL REFERENCES "b"("key") ON DELETE RESTRICT,
  "c_key" INTEGER NOT NULL REFERENCES "c"("key") ON DELETE RESTRICT,
  PRIMARY KEY ("a_key", "b_key", "c_key")
) STRICT;

CREATE TABLE "a__n__a" (
  "left_key" INTEGER NOT NULL REFERENCES "Parent"("key") ON DELETE RESTRICT,
  "right_key" INTEGER NOT NULL REFERENCES "Parent"("key") ON DELETE RESTRICT,
  PRIMARY KEY ("left_key", "right_key")
) STRICT;

CREATE TABLE "a__n__a__n__b" (
  "left_key" INTEGER NOT NULL REFERENCES "Parent"("key") ON DELETE RESTRICT,
  "right_key" INTEGER NOT NULL REFERENCES "Parent"("key") ON DELETE RESTRICT,
  "b_key" INTEGER NOT NULL REFERENCES "b"("key") ON DELETE RESTRICT,
  PRIMARY KEY ("left_key", "right_key", "b_key")
) STRICT;

CREATE TABLE "Parent" (
  "key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "b" (
  "key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE TABLE "c" (
  "key" INTEGER PRIMARY KEY AUTOINCREMENT
) STRICT;

CREATE INDEX "a__n__b__n__c_b_key_idx" ON "a__n__b__n__c" ("b_key");

CREATE INDEX "a__n__b__n__c_c_key_idx" ON "a__n__b__n__c" ("c_key");

CREATE INDEX "a__n__a_right_key_idx" ON "a__n__a" ("right_key");

CREATE INDEX "a__n__a__n__b_right_key_idx" ON "a__n__a__n__b" ("right_key");

CREATE INDEX "a__n__a__n__b_b_key_idx" ON "a__n__a__n__b" ("b_key");
