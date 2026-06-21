import SwiftOpenAPI
import Vapor
@testable import VaporToOpenAPI
import XCTest

final class DTOInferenceTests: XCTestCase {

	func testDictionaryOfAssociatedValueEnumDoesNotDropFollowingProperties() throws {
		var schemas: ComponentsMap<SchemaObject> = [:]
		let body: OpenAPIBody = .type([InventoryItemDTO].self)

		_ = try body.value.schema(schemas: &schemas)
		guard
			let itemSchema = schemas["InventoryItemDTO"]?.object,
			case let .object(context) = itemSchema.context
		else {
			XCTFail("Expected InventoryItemDTO component schema")
			return
		}

		XCTAssertEqual(
			Set(context.properties?.keys ?? []),
			["id", "name", "attributes", "externalCode"]
		)
		XCTAssertEqual(context.properties?["externalCode"], .string.with(\.nullable, true))
		XCTAssertEqual(
			context.properties?["attributes"],
			.dictionary(of: .any)
		)
	}
}

struct InventoryItemDTO: Content {

	let id: UUID
	let name: String
	let attributes: [String: InventoryAttributeDTO]
	let externalCode: String?
}

enum InventoryAttributeDTO: Content {

	case quantity(value: Double, unit: InventoryUnitDTO, id: UUID)
	case range(min: Double, max: Double, id: UUID)
	case label(value: String, id: UUID)
}

enum InventoryUnitDTO: String, Content, CaseIterable {

	case piece
	case kilogram
	case liter
	case invalid
}
