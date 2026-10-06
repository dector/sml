--- Owners table
Owner {
  #name `Owners`
  --- Cross collection
  -- ordinary comments preserve attachment
  ~items Item[] @Item.owner
  --- Owner key
  !id int {
    #name `Key`
  }
  --- Cross singular
  ~profile Item? @Item.owner
  label str
}
Item {
  #name `Items`
  note str
  --- Stored owner
  *owner Owner? {
    #name `OwnerKey`
    ? unique {
      #name `one owner`
    }
  }
}
Node {
  #name `Nodes`
  --- Self collection
  ~children Node[] @Node.parent
  !id int
  --- Self singular
  ~child Node? @Node.parent
  --- Stored parent
  *parent Node? {
    ? unique {
      #name `one parent`
    }
  }
}
