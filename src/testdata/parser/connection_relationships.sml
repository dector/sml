Reader {
  !id int
  ~following Reader[] @Following.leftReader
  ~pairs Reader[] @Trio.first <<second
  ~one Book? @Single.reader
}

Book {
  !id int
}

~Following(follower Reader, followed Reader) {
  *!leftReader Reader
  *!rightReader Reader
}

~Trio(a Reader, b Reader, c Reader) {
  *!first Reader
  *!second Reader
  *!third Reader
}

~Single(Reader, Book) {
  *!reader Reader {
    ? unique
  }
  *!book Book
}
