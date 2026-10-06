Ranges {
  ?? lower <= upper
  #name `ranges`
  !groupId int
  !entryId int
  lower int? {
    #name `low"value`
    ? _ >= 0
  }
  #check lower == null || upper != null
  upper int? {
    #name `high value`
  }
  #check `"high value" < 100`
}

Flags {
  #check enabled
  enabled bool?
}

Times {
  ?? finish >= start
  start datetime?
  finish datetime?
}
