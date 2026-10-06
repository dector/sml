--- Forward connection endpoints expand the whole target tuple.
~Credit(Authorship, Organization) {
  ~~
}
~ExplicitCredit(pair Authorship, Organization) {
  *!pair Authorship
  *!organizationId Organization
}
~CascadeCredit(Authorship, Organization) {
  ~~
  *!authorshipAuthorId Authorship {
    #onDelete cascade
  }
  *!authorshipBookId Authorship {
    #onDelete cascade
  }
}
~TupleCascadeCredit(Authorship, Organization) {
  *!pair Authorship {
    #onDelete cascade
  }
  *!organizationId Organization
}
~Approval(Credit, Reviewer) {
  ~~
}
~(Authorship, Reviewer) {
  ~~
}
~Authorship(Author, Book) {
  ~~
}
Author {
  !id int
}
Book {
  !id int
}
Organization {
  !id int
}
Reviewer {
  !id int
}
