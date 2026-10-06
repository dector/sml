~Pair(Author, State) {
  amount int(2)
  --- The writer override keeps its own docs.
  *!authorId Author(1) {
    #name `writer_id`
    #onDelete cascade
    #check _ > 0
  }
  note str('unchanged')
  *!stateCode State(ready) {
    #name `status`
    ? unique
  }
  ~~
  #index authorId, stateCode
}
~Self(left Author, right Author, context Author) {
  label str('ready')
  *!contextId Author(3)
  ~~
  *!leftId Author {
    #name `first_id`
  }
  #index rightId, leftId
}
Author {
  !id int {
    #name `Actual Key`
  }
}
State {
  !code enum {
    #of ready, done
  }
}
