Record {
  #name `record store`
  #index email {
    #unique
    #name `active email`
    #where deletedAt == null
  }
  email str? {
    #index {
      #name `boolean lookup`
      #where (
        active && low < high
      )
    }
  }
  deletedAt int? {
    #name `deleted at`
  }
  active bool
  low int
  high int
  #index low, high {
    #name `raw lookup`
    #where #`"deleted at" IS NULL AND "low" < "high"`#
  }
}
