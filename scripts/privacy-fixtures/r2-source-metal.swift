// into: App/Sources
// filename: Escape.metal
// expect: cannot read compiled source
void f() { fstat (fd, &info); }
