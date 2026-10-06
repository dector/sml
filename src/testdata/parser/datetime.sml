--- UTC events.
Event {
  !at datetime('2000-02-29T23:59:59Z')
  createdAt datetime(::now)
  optional datetime?(null)
  raw datetime(`'0001-01-01T00:00:00Z'`)
  now str('contextual identifier')
}

Pair {
  !start datetime
  !end datetime
}
