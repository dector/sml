Identity {
  #name `Identity Exact`
  !id int =
    #name `Key Exact`
}

Shared {
  *!identity Identity =
    #onDelete cascade
}

DefaultShared {
  *!identity Identity(7)
}

Chain {
  *!identity Shared =
    #onDelete cascade
}

Tuple {
  *!identity Identity
  !part int
}

TextIdentity {
  !key str
}

TextShared {
  *!identity TextIdentity('seed')
}

TextRequired {
  *!identity TextIdentity
}

EnumIdentity {
  !key enum =
    #of ready, done
}

EnumShared {
  *!identity EnumIdentity(ready)
}

TimeIdentity {
  !key datetime
}

TimeShared {
  *!identity TimeIdentity('2000-02-29T00:00:00Z')
}
