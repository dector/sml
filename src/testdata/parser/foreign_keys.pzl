Child {
  *owner Parent?(7) {
    #name `Owner Exact`
    #check _ > 0
    ? unique
  }
  *label Label?('seed')
  *state State?(ready)
  *stamp Clock?('2000-02-29T00:00:00Z')
  #check owner > 0
  #index label
}
Parent {
  #name `Parent Exact`
  !key int {
    #name `Key Exact`
  }
}
Label {
  !key str
}
State {
  !key enum {
    #of ready, done
  }
}
Clock {
  !key datetime
}
Node {
  !id int
  *parent Node?
}
Left {
  !id int
  *right Right?
}
Right {
  !id int
  *left Left?
}
CascadeParent {
  !id real
}
CascadeChild {
  !id int
  *parent CascadeParent =
    #onDelete cascade
}
CascadeLeaf {
  !id int
  *parent CascadeChild {
    #onDelete cascade
  }
}
NullChild {
  !id int
  *parent CascadeParent? =
    #onDelete setNull
}
CascadeNode {
  !id int
  *parent CascadeNode? =
    #onDelete cascade
}
