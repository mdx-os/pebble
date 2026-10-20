// into: Packages/PebbleKit/Sources/PebbleUI
// expect: a system API that sends the person's data to Apple's servers
import MapKit

func fixtureSearch(_ request: MKLocalSearch.Request) -> MKLocalSearch { MKLocalSearch(request: request) }
