Child {
  *bare enum(ready)
  *quoted enum(`it's ready`)
}

enum {
  #name `Enum Exact`
  !key enum {
    #name `Enum Key`
    #of ready, `it's ready`
  }
}
