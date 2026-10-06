Ranges {
  #name `named ranges`
  ?? (lower <= upper) {
    #name `range "order"`
  }
  lower int? {
    #name `low value`
    ? (_ >= 0) {
      #name #`nonnegative `lower``#
    }
    #check _ != null || _ == null {}
  }
  upper int? {
    #check `"upper" IS NULL OR "upper" < 100` {
      #name #`upper ` limit`#
    }
  }
  #check lower == null || upper != null {
    #name `upper required`
  }
}
Flags {
  enabled bool? {
    ? _ != false {
      #name `enabled only`
    }
  }
}
Safe {
  n int {
    #check _ > 0 {
      #name `safe"); DROP TABLE flags; --`
    }
  }
}
