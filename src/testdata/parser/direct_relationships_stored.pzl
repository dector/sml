--- Owners table
Owner {
  #name `Owners`
  --- Owner key
  !id int {
    #name `Key`
  }
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
  !id int
  --- Stored parent
  *parent Node? {
    ? unique {
      #name `one parent`
    }
  }
}
