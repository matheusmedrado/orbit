import SwiftUI

/// `@State` on this SDK is a macro whose plugin ships with Xcode, not the
/// Command Line Tools. `State` is still a property wrapper, so this name
/// reaches that wrapper and the menu bar app can build without Xcode.
typealias UIState<Value> = State<Value>
