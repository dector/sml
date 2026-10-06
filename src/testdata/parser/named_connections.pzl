--- People with real keys.
Reader {
  #name `People Exact`
  !key real {
    #name `Person Key`
  }
  --- Virtual books, not SQL documentation.
  ~books Book[] @Borrow._sourceId
  --- Virtual peers, preserving triples.
  ~peers Reader[] @Trio.origin <<destination
}
Book {
  #name `Books Exact`
  !key str {
    #name `Book Key`
  }
}
--- Explicit stored borrow tuples.
~Borrow(person Reader, publication Book) {
  #name `Borrow Exact`
  *!arbitrary Book {
    #name `Book Ref`
  }
  --- Extra value documentation.
  amount int(2) {
    ? _ > 0
  }
  *!_sourceId Reader {
    #name `Person Ref`
    #onDelete cascade
  }
  state enum(ready) {
    #of ready, done
  }
  createdAt datetime('2000-02-29T00:00:00Z')
  tag str {
    ? unique
  }
  #check amount < 10
  #index state {
    #name `State Lookup`
  }
}
--- Three-role stored tuples.
~Trio(originRole Reader, destinationRole Reader, contextRole Reader) {
  #name `Triple Exact`
  *!context Reader {
    #name `Context Ref`
  }
  note str('seed')
  *!destination Reader {
    #name `Destination Ref`
  }
  *!origin Reader {
    #name `Origin Ref`
  }
}
