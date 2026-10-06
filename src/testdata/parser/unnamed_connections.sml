~(Book, Author) {
  #name `Library Links`
  ~~
  *!bookId Book {
    #name `volume`
  }
  note str('ready')
}

Author {
  #name `Writer`
  !id int
}

Book {
  !id int
}
