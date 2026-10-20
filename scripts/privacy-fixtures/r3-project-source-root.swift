// into: Extra
// project: s~(      - App/Sources\n)~$1      - Extra\n~
// expect: network code outside the opt-in cloud client
// A source folder outside App that project.yml compiles into the app.
import Foundation

let fixtureExtra = URLSession.shared
