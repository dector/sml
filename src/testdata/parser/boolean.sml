Flags {
  !id int
  enabled bool(true)
  disabled bool(false)
  optional bool?
  unknown bool?(null)
  converted bool(`1 = 1`) {
    #name #`a"b`c`#
  }
}
