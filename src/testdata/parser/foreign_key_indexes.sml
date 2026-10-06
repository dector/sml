Child {
  *!first Parent
  *!second Parent
  *native Parent? {
    ? unique
  }
  *composite Parent?
  *tail Parent?
  *ordinary Parent?
  *uniqueIndex Parent?
  *partial Parent?
  *partialUnique Parent?
  *truth Parent?
  #index tail, second
  #index ordinary, tail
  #index uniqueIndex, tail {
    #unique
  }
  #index partial {
    #name `partial lookup`
    #where #`partial IS NOT NULL`#
  }
  #index partialUnique {
    #name `partial unique lookup`
    #unique
    #where partialUnique != null
  }
  #index truth {
    #name `true lookup`
    #where true
  }
  ?? unique(composite, tail)
}
Parent {
  !id int
}
Shared {
  *!id Parent
}
Rowid {
  !id int
  *parent Parent? {
    ? unique
  }
}
