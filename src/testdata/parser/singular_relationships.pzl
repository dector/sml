Owner {
!id int
~fieldProfile FieldProfile? @FieldProfile.owner
~tableProfile TableProfile? @TableProfile.owner
~indexProfile IndexProfile? @IndexProfile.owner
~sharedProfile SharedProfile? @SharedProfile.owner
}
FieldProfile {
*owner Owner? {
? unique
}
}
TableProfile {
*owner Owner?
?? unique(owner)
}
IndexProfile {
*owner Owner?
#index owner {
#unique
}
}
SharedProfile {
*!owner Owner
}
