--- Calendar days.
Day {
  !at date(##'2000-02-29'##)
  optional date?(null)
  raw date(`'0001-01-01'`)
}

Range {
  start date =
    #check _ >= '0001-01-01'
  finish date?
  #check finish == null || finish >= start
}

Ref {
  *day Day('2000-02-29')
}

Pair {
  !start date
  !finish date
}
