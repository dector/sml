~(C, B, A) {
  ~~
  *!aKey A(1) {
    #onDelete cascade
  }
}
~(right A, left A) {
  ~~
}
~(right A, B, left A) {
  ~~
}
A {
  #name `Parent`
  !key int
  ~others A[] @.leftKey <<rightKey
}
B {
  !key int
}
C {
  !key int
}
