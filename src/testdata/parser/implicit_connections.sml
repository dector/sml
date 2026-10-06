Author {
  #name `writers`
  !id int {
    #name `writer_key`
  }
  --- Books are virtual.
  ~books Book[] @.authorId
}

Book {
  !id int
  ~authors Author[] @.bookId <<authorId
}
