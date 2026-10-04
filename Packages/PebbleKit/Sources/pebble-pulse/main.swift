import Foundation
import PebblePulse

@main
enum PulseMain {
    static func main() async {
        let code = await PulseCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
        if code != 0 {
            exit(Int32(code))
        }
    }
}
