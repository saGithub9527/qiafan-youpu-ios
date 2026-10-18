import Foundation

@main enum ScrollFollowCheck {
  static func main() {
    var state = QFAssistantScrollFollow()
    precondition(state.canFollow)
    state.beginDragging()
    state.didScroll(distanceFromBottom: 35)
    precondition(!state.followsLatest, "Dragging near the bottom must not re-enable follow")
    precondition(!state.canFollow)
    state.didScroll(distanceFromBottom: -8) // elastic bounce is still part of the gesture
    precondition(!state.canFollow)
    state.finishGesture(distanceFromBottom: 160)
    precondition(!state.canFollow && !state.isInteracting)
    state.didScroll(distanceFromBottom: 4) // programmatic/layout change cannot opt the reader in
    precondition(!state.canFollow)
    state.beginDragging()
    state.didScroll(distanceFromBottom: 0)
    precondition(!state.canFollow)
    state.finishGesture(distanceFromBottom: 0)
    precondition(state.canFollow)
    state.beginDragging()
    state.finishGesture(distanceFromBottom: 400)
    state.jumpToLatest()
    precondition(state.canFollow)
    print("PASS scroll ownership: drag, deceleration, bounce, manual return, explicit jump")
  }
}
