import XCTest
@testable import LocalBrainKit

final class ModelRoleTests: XCTestCase {
    func testTheGroundingRoleNeedsVisionAndDefaultsToTheGroundingModel() {
        XCTAssertEqual(ModelRole.grounding.requiredCapability, "vision")
        XCTAssertEqual(ModelRole.grounding.defaultModel, LocalModels.defaultGroundingModel)
        XCTAssertEqual(ModelRole.grounding.displayName, "Pointing model")
    }

    func testTheOtherRolesAreUnchanged() {
        XCTAssertEqual(ModelRole.chat.requiredCapability, "completion")
        XCTAssertEqual(ModelRole.vision.requiredCapability, "vision")
        XCTAssertEqual(ModelRole.chat.defaultModel, LocalModels.defaultChatModel)
        XCTAssertEqual(ModelRole.vision.defaultModel, LocalModels.defaultVisionModel)
        XCTAssertEqual(Set(ModelRole.allCases), [.chat, .vision, .grounding])
    }
}
