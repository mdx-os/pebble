import PebbleCore
import Testing

struct FirstConversationTests {
    let brand = Brand(name: "Nova")

    @Test func openingUsesTheNameItIsGiven() {
        #expect(FirstConversation.opening(named: "Nova") == "Hi, I'm Nova. Pick a place to start, or tell me what's on your mind.")
    }

    @Test func openingCanUseADifferentNameThanTheProduct() {
        let greeting = FirstConversation.opening(named: "Pip")
        #expect(greeting.contains("Pip"))
        #expect(!greeting.contains(brand.name))
    }

    @Test func offersThreeStarterJobs() {
        let jobs = FirstConversation.jobs
        #expect(jobs.map(\.id) == ["morning", "talk", "remember"])
        #expect(Set(jobs.map(\.title)).count == 3)
        #expect(Set(jobs.map(\.prompt)).count == 3)
        #expect(jobs.allSatisfy { !$0.title.isEmpty && !$0.prompt.isEmpty })
    }

    @Test func presenceStaysOnDevice() {
        #expect(FirstConversation.presence == "Here with you, on this device.")
    }
}
