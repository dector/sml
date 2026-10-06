Measurements {
  #name `samples`
  optional int? =
    ? _ > 0
    #check _ < 10
    #name `opt"value`
  required int {
    ? (
      _ >= 0 && -- bounds
      _ <= 10
    )
  }
  present int? =
    #check _ != (null)
  flag bool? {
    ? _
    #check _ == true
  }
  state enum?(ready) =
    #of ready, done
    ? _ != 'done'
  created datetime? {
    #check _ >= '2000-01-01T00:00:00Z'
  }
  other int =
    #check `other >= required`
  label str =
    ? _ != 'bad'
    #check _ != #'no'#
  empty str {}
}
