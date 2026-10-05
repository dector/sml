Record {
#name `record store`
a int? {
#name `first`
#index {
#unique
#name `first lookup`
}
? unique {
#name `first lookup`
}
}
b int? {
#index
}
c int? 
#index b {
#unique
#name `single b`
}
#index c, b {
#name `pair lookup`
#unique
}
#index c, b
}
Pair {
a int?
b int?
#index b, a {
#unique
}
}
Other {
value int? {
#index {
#unique
}
}
}
