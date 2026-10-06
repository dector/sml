--- Generated pairs use header order even when the marker is last.
~Pair(writer Author, Snake_Name) {
  *!writerAccountKey Author
  *!snakeNameAccountKey Snake_Name
  amount int(2)
  *cleanup Author? {
    #onDelete cascade
  }
}
~Trio(left Author, right Author, context Author) {
  *!leftAccountKey Author
  *!rightAccountKey Author
  *!contextAccountKey Author
  label str('ready')
}
~Kinds(State, Clock, Alias) {
  *!stateStateKey State
  *!clockMoment Clock
  *!aliasExternalKey Alias
}
Author {
  !accountKey int {
    #name `Actual Key`
  }
  #name `Author Exact`
  ~snakes Snake_Name[] @Pair.writerAccountKey
}
Snake_Name {
  !account_key str
}
State {
  !state_key enum(ready) {
    #of ready, done
  }
}
Clock {
  !moment datetime
}
Alias {
  *!external_key Author
}
