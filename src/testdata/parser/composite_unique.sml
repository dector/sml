Pairs {
  ?? unique(right, left) {
    #name #`pair"constraint`#
  }
  #check unique(flag)
  ! keyA int
  ! keyB int
  left str? {
    #name `left value`
    ? _ != ''
  }
  right str? {
    #name #`right"value`#
  }
  flag bool?
  ?? keyA > 0
}

Other {
  a int
  b int
  #check unique(a, b) {}
}
