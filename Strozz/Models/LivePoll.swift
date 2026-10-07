import Foundation

/// A live poll running on the watched channel.
struct LivePoll: Equatable, Identifiable {
  struct Choice: Equatable, Identifiable {
    let id: String
    let title: String
    let votes: Int
  }
  let id: String
  let title: String
  let choices: [Choice]
  let isActive: Bool

  var totalVotes: Int { choices.reduce(0) { $0 + $1.votes } }
  func fraction(of choice: Choice) -> Double {
    totalVotes > 0 ? Double(choice.votes) / Double(totalVotes) : 0
  }
}
