Records {
  #index second, first
  #name `record" store`
  first str =
    #index {
      #name #`first" lookup`#
    }
    #check _ != ''
    #index {}
  second int {
    #name `second value`
    #index
  }
  #index second, first {
    #name `alternate`
  }
  ?? unique(first) {
    #name `alternate`
  }
}

Other {
  value int {
    #index
  }
}
