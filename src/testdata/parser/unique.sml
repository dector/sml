UniqueValues {
#name `unique values`
code str?('default') {
#name `exact code`
? _ != 'bad'
? unique {
#name #`code"constraint`#
}
}
number int?(null) {
#check unique {}
}
flag bool? {
? unique
}
created datetime? {
? unique
}
choice enum? {
#of a, b
? unique
}
payload blob? {
? unique
}
ratio real? {
? unique
}
raw str?(`'raw'`) {
? unique
}
}
