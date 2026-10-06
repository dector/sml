Child {
  *parent enum(1)
  *clock datetime(2)
  *choice str(`it's ready`)
}

enum {
  #name `Enum Exact`
  !key int {
    #name `Integer Key`
  }
}

datetime {
  #name `Datetime Exact`
  !key int
}

str {
  #name `Str Exact`
  !key enum {
    #of `it's ready`, done
  }
}
