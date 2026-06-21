import Foundation
import SwiftOpenAPI

enum SchemaInferenceFallback {

	/// Keeps SwiftOpenAPI's inferred schema unless a nested decode aborts object
	/// discovery before all sibling properties are recorded.
	static func decodeSchema(
		_ type: Decodable.Type,
		into schemas: inout ComponentsMap<SchemaObject>
	) throws -> ReferenceOr<SchemaObject> {
		let initialSchemas = schemas

		var originalSchemas = schemas
		let original = Result {
			try ReferenceOr<SchemaObject>.decodeSchema(type, into: &originalSchemas)
		}

		let fallbackContext = PropertySchemaContext(schemas: initialSchemas)
		let fallback = Result {
			try fallbackContext.schema(for: type)
		}

		switch (original, fallback) {
		case let (.success(originalSchema), .success(fallbackSchema)):
			if fallbackContext.schemas.hasMoreCompleteObjects(than: originalSchemas, baseline: initialSchemas) {
				schemas = fallbackContext.schemas
				return fallbackSchema
			}
			schemas = originalSchemas
			return originalSchema

		case let (.success(originalSchema), .failure):
			schemas = originalSchemas
			return originalSchema

		case let (.failure, .success(fallbackSchema)):
			schemas = fallbackContext.schemas
			return fallbackSchema

		case let (.failure(error), .failure):
			throw error
		}
	}
}

private final class PropertySchemaContext {

	var schemas: ComponentsMap<SchemaObject>
	private var visiting: Set<ObjectIdentifier> = []

	init(schemas: ComponentsMap<SchemaObject>) {
		self.schemas = schemas
	}

	func schema(for type: Decodable.Type) throws -> ReferenceOr<SchemaObject> {
		if let schema = try knownSchema(for: type) {
			return schema
		}

		let name = String.schemaInferenceTypeName(type)
		let identifier = ObjectIdentifier(type)
		if schemas[name] != nil || visiting.contains(identifier) {
			return .ref(components: \.schemas, name)
		}

		visiting.insert(identifier)
		defer { visiting.remove(identifier) }

		let decoder = PropertySchemaDecoder(context: self)
		_ = try type.init(from: decoder)
		return store(decoder.schema, for: type)
	}

	func schemaAndMock<T: Decodable>(for type: T.Type) throws -> (schema: ReferenceOr<SchemaObject>, value: T) {
		if let schema = try knownSchema(for: type), let value = mockValue(for: type) as? T {
			return (schema, value)
		}

		let identifier = ObjectIdentifier(type)
		guard !visiting.contains(identifier) else {
			throw PropertySchemaError.recursiveType
		}

		visiting.insert(identifier)
		defer { visiting.remove(identifier) }

		let decoder = PropertySchemaDecoder(context: self)
		let value = try T(from: decoder)
		return (store(decoder.schema, for: type), value)
	}

	private func knownSchema(for type: Decodable.Type) throws -> ReferenceOr<SchemaObject>? {
		if let primitive = type as? any PropertySchemaPrimitive.Type {
			return primitive.schemaInferenceSchema
		}

		if let collection = type as? AnyCollectionSchema.Type {
			let itemSchema = try schemaForNestedValue(collection.elementType)
			return .array(of: itemSchema, uniqueItems: collection.uniqueItems)
		}

		if let dictionary = type as? AnyDictionarySchema.Type, dictionary.keyType == String.self {
			let valueSchema = try schemaForNestedValue(dictionary.valueType)
			return .dictionary(of: valueSchema)
		}

		if let schema = enumSchema(for: type) {
			return store(schema, for: type)
		}

		if let openAPI = type as? OpenAPIType.Type {
			return store(.value(openAPI.openAPISchema), for: type)
		}

		return nil
	}

	private func schemaForNestedValue(_ type: Any.Type) throws -> ReferenceOr<SchemaObject> {
		guard let decodable = type as? Decodable.Type else {
			return .any
		}

		let savedSchemas = schemas
		do {
			return try schema(for: decodable)
		} catch {
			schemas = savedSchemas
			return .any
		}
	}

	private func store(
		_ schema: ReferenceOr<SchemaObject>,
		for type: Any.Type
	) -> ReferenceOr<SchemaObject> {
		guard var object = schema.object, object.isSchemaInferenceReferenceable else {
			return schema
		}

		let name = String.schemaInferenceTypeName(type)
		object.nullable = nil
		schemas[name] = .value(object)
		return .ref(components: \.schemas, name)
	}

	private func enumSchema(for type: Any.Type) -> ReferenceOr<SchemaObject>? {
		guard let iterable = type as? any CaseIterable.Type else {
			return nil
		}

		let allCases = iterable.allCases as any Collection
		let values = allCases.map { caseValue(for: $0) }
		guard !values.isEmpty else {
			return nil
		}

		if values.allSatisfy({ $0 is Int }) {
			return .enum(of: .integer, cases: values.compactMap { ($0 as? Int).map(AnyValue.int) })
		}

		if values.allSatisfy({ $0 is Double }) {
			return .enum(of: .number, cases: values.compactMap { ($0 as? Double).map(AnyValue.double) })
		}

		return .enum(cases: values.map { .string("\($0)") })
	}

	private func mockValue(for type: Decodable.Type) -> Decodable? {
		if let primitive = type as? any PropertySchemaPrimitive.Type {
			return primitive.schemaInferenceMock
		}
		if let collection = type as? AnyCollectionSchema.Type {
			return collection.emptyValue() as? Decodable
		}
		if let dictionary = type as? AnyDictionarySchema.Type {
			return dictionary.emptyValue() as? Decodable
		}
		if let iterable = type as? any CaseIterable.Type {
			let allCases = iterable.allCases as any Collection
			return allCases.firstValue as? Decodable
		}
		return nil
	}

	private func caseValue(for value: Any) -> Any {
		if let raw = value as? any RawRepresentable {
			return raw.rawValue
		}
		return "\(value)"
	}
}

private protocol PropertySchemaPrimitive: Decodable {

	static var schemaInferenceSchema: ReferenceOr<SchemaObject> { get }
	static var schemaInferenceMock: Self { get }
}

private extension PropertySchemaPrimitive where Self: OpenAPIType {

	static var schemaInferenceSchema: ReferenceOr<SchemaObject> {
		.value(openAPISchema)
	}
}

extension Bool: PropertySchemaPrimitive {

	static let schemaInferenceSchema: ReferenceOr<SchemaObject> = .boolean
	static let schemaInferenceMock = false
}

extension String: PropertySchemaPrimitive {

	static let schemaInferenceMock = ""
}

extension Double: PropertySchemaPrimitive {

	static let schemaInferenceMock = 0.0
}

extension Float: PropertySchemaPrimitive {

	static let schemaInferenceMock: Float = 0
}

extension Int: PropertySchemaPrimitive {

	static let schemaInferenceMock = 0
}

extension Int8: PropertySchemaPrimitive {

	static let schemaInferenceMock: Int8 = 0
}

extension Int16: PropertySchemaPrimitive {

	static let schemaInferenceMock: Int16 = 0
}

extension Int32: PropertySchemaPrimitive {

	static let schemaInferenceMock: Int32 = 0
}

extension Int64: PropertySchemaPrimitive {

	static let schemaInferenceMock: Int64 = 0
}

extension UInt: PropertySchemaPrimitive {

	static let schemaInferenceMock: UInt = 0
}

extension UInt8: PropertySchemaPrimitive {

	static let schemaInferenceMock: UInt8 = 0
}

extension UInt16: PropertySchemaPrimitive {

	static let schemaInferenceMock: UInt16 = 0
}

extension UInt32: PropertySchemaPrimitive {

	static let schemaInferenceMock: UInt32 = 0
}

extension UInt64: PropertySchemaPrimitive {

	static let schemaInferenceMock: UInt64 = 0
}

extension Date: PropertySchemaPrimitive {

	static let schemaInferenceMock = Date()
}

extension Data: PropertySchemaPrimitive {

	static let schemaInferenceMock = Data()
}

extension UUID: PropertySchemaPrimitive {

	static let schemaInferenceMock = UUID()
}

extension URL: PropertySchemaPrimitive {

	static let schemaInferenceMock = URL(string: "https://github.com/dankinsoid/VaporToOpenAPI")!
}

extension Decimal: PropertySchemaPrimitive {

	static let schemaInferenceMock = Decimal(0)
}

private final class PropertySchemaDecoder: Decoder {

	let context: PropertySchemaContext
	var codingPath: [CodingKey]
	var userInfo: [CodingUserInfoKey: Any] = [:]

	private let storage = PropertySchemaStorage()

	var schema: ReferenceOr<SchemaObject> {
		storage.schema ?? (storage.isKeyed ? storage.keyed.schema : .any)
	}

	init(context: PropertySchemaContext, codingPath: [CodingKey] = []) {
		self.context = context
		self.codingPath = codingPath
	}

	func container<Key: CodingKey>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> {
		storage.isKeyed = true
		storage.keyed = PropertySchemaKeyedStorage()
		return KeyedDecodingContainer(
			PropertySchemaKeyedDecodingContainer<Key>(
				decoder: self,
				storage: storage.keyed
			)
		)
	}

	func unkeyedContainer() throws -> UnkeyedDecodingContainer {
		PropertySchemaUnkeyedDecodingContainer(decoder: self, storage: storage)
	}

	func singleValueContainer() throws -> SingleValueDecodingContainer {
		PropertySchemaSingleValueDecodingContainer(decoder: self, storage: storage)
	}
}

private final class PropertySchemaStorage {

	var schema: ReferenceOr<SchemaObject>?
	var isKeyed = false
	var keyed = PropertySchemaKeyedStorage()
}

private final class PropertySchemaKeyedStorage {

	var properties: ComponentsMap<SchemaObject> = [:]
	var required: Set<String> = []

	var schema: ReferenceOr<SchemaObject> {
		.object(properties: properties, required: required)
	}
}

private struct PropertySchemaKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

	var codingPath: [CodingKey] {
		decoder.codingPath
	}

	var allKeys: [Key] {
		[]
	}

	let decoder: PropertySchemaDecoder
	let storage: PropertySchemaKeyedStorage

	func contains(_: Key) -> Bool {
		true
	}

	func decodeNil(forKey key: Key) throws -> Bool {
		record(.any, forKey: key, optional: true)
		return false
	}

	func decodeIfPresent(_: Bool.Type, forKey key: Key) throws -> Bool? {
		decodePrimitiveIfPresent(Bool.self, forKey: key)
	}

	func decodeIfPresent(_: String.Type, forKey key: Key) throws -> String? {
		decodePrimitiveIfPresent(String.self, forKey: key)
	}

	func decodeIfPresent(_: Double.Type, forKey key: Key) throws -> Double? {
		decodePrimitiveIfPresent(Double.self, forKey: key)
	}

	func decodeIfPresent(_: Float.Type, forKey key: Key) throws -> Float? {
		decodePrimitiveIfPresent(Float.self, forKey: key)
	}

	func decodeIfPresent(_: Int.Type, forKey key: Key) throws -> Int? {
		decodePrimitiveIfPresent(Int.self, forKey: key)
	}

	func decodeIfPresent(_: Int8.Type, forKey key: Key) throws -> Int8? {
		decodePrimitiveIfPresent(Int8.self, forKey: key)
	}

	func decodeIfPresent(_: Int16.Type, forKey key: Key) throws -> Int16? {
		decodePrimitiveIfPresent(Int16.self, forKey: key)
	}

	func decodeIfPresent(_: Int32.Type, forKey key: Key) throws -> Int32? {
		decodePrimitiveIfPresent(Int32.self, forKey: key)
	}

	func decodeIfPresent(_: Int64.Type, forKey key: Key) throws -> Int64? {
		decodePrimitiveIfPresent(Int64.self, forKey: key)
	}

	func decodeIfPresent(_: UInt.Type, forKey key: Key) throws -> UInt? {
		decodePrimitiveIfPresent(UInt.self, forKey: key)
	}

	func decodeIfPresent(_: UInt8.Type, forKey key: Key) throws -> UInt8? {
		decodePrimitiveIfPresent(UInt8.self, forKey: key)
	}

	func decodeIfPresent(_: UInt16.Type, forKey key: Key) throws -> UInt16? {
		decodePrimitiveIfPresent(UInt16.self, forKey: key)
	}

	func decodeIfPresent(_: UInt32.Type, forKey key: Key) throws -> UInt32? {
		decodePrimitiveIfPresent(UInt32.self, forKey: key)
	}

	func decodeIfPresent(_: UInt64.Type, forKey key: Key) throws -> UInt64? {
		decodePrimitiveIfPresent(UInt64.self, forKey: key)
	}

	func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
		let result = try decoder.context.schemaAndMock(for: type)
		record(result.schema, forKey: key)
		return result.value
	}

	func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
		let schema = (try? decoder.context.schema(for: type)) ?? .any
		record(schema.with(\.nullable, true), forKey: key, optional: true)
		return nil
	}

	func nestedContainer<NestedKey: CodingKey>(
		keyedBy _: NestedKey.Type,
		forKey key: Key
	) throws -> KeyedDecodingContainer<NestedKey> {
		let nested = PropertySchemaKeyedStorage()
		record(nested.schema, forKey: key)
		return KeyedDecodingContainer(
			PropertySchemaKeyedDecodingContainer<NestedKey>(
				decoder: decoder,
				storage: nested
			)
		)
	}

	func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
		let nested = PropertySchemaStorage()
		record(.array(of: .any), forKey: key)
		return PropertySchemaUnkeyedDecodingContainer(decoder: decoder, storage: nested)
	}

	func superDecoder() throws -> Decoder {
		PropertySchemaDecoder(context: decoder.context, codingPath: codingPath)
	}

	func superDecoder(forKey key: Key) throws -> Decoder {
		PropertySchemaDecoder(context: decoder.context, codingPath: codingPath + [key])
	}

	private func record(
		_ schema: ReferenceOr<SchemaObject>,
		forKey key: Key,
		optional: Bool = false
	) {
		storage.properties[key.stringValue] = schema
		if !optional {
			storage.required.insert(key.stringValue)
		}
	}

	private func decodePrimitiveIfPresent<Value: PropertySchemaPrimitive>(
		_: Value.Type,
		forKey key: Key
	) -> Value? {
		record(Value.schemaInferenceSchema.with(\.nullable, true), forKey: key, optional: true)
		return nil
	}
}

private struct PropertySchemaSingleValueDecodingContainer: SingleValueDecodingContainer {

	var codingPath: [CodingKey] {
		decoder.codingPath
	}

	let decoder: PropertySchemaDecoder
	let storage: PropertySchemaStorage

	func decodeNil() -> Bool {
		storage.schema = .any
		return false
	}

	func decode<T: Decodable>(_ type: T.Type) throws -> T {
		let result = try decoder.context.schemaAndMock(for: type)
		storage.schema = result.schema
		return result.value
	}
}

private struct PropertySchemaUnkeyedDecodingContainer: UnkeyedDecodingContainer {

	var codingPath: [CodingKey] {
		decoder.codingPath
	}

	var count: Int? {
		0
	}

	var isAtEnd: Bool {
		currentIndex > 0
	}

	var currentIndex = 0

	let decoder: PropertySchemaDecoder
	let storage: PropertySchemaStorage

	mutating func decodeNil() throws -> Bool {
		storage.schema = .array(of: .any)
		currentIndex = 1
		return false
	}

	mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
		let result = try decoder.context.schemaAndMock(for: type)
		storage.schema = .array(of: result.schema)
		currentIndex = 1
		return result.value
	}

	mutating func nestedContainer<NestedKey: CodingKey>(
		keyedBy _: NestedKey.Type
	) throws -> KeyedDecodingContainer<NestedKey> {
		let nested = PropertySchemaKeyedStorage()
		storage.schema = .array(of: nested.schema)
		return KeyedDecodingContainer(
			PropertySchemaKeyedDecodingContainer<NestedKey>(
				decoder: decoder,
				storage: nested
			)
		)
	}

	mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
		let nested = PropertySchemaStorage()
		storage.schema = .array(of: .any)
		return PropertySchemaUnkeyedDecodingContainer(decoder: decoder, storage: nested)
	}

	mutating func superDecoder() throws -> Decoder {
		PropertySchemaDecoder(context: decoder.context, codingPath: codingPath)
	}
}

private protocol AnyCollectionSchema {

	static var elementType: Any.Type { get }
	static var uniqueItems: Bool? { get }
	static func emptyValue() -> Any
}

extension Array: AnyCollectionSchema {

	static var elementType: Any.Type {
		Element.self
	}

	static var uniqueItems: Bool? {
		nil
	}

	static func emptyValue() -> Any {
		Self()
	}
}

extension Set: AnyCollectionSchema {

	static var elementType: Any.Type {
		Element.self
	}

	static var uniqueItems: Bool? {
		true
	}

	static func emptyValue() -> Any {
		Self()
	}
}

private protocol AnyDictionarySchema {

	static var keyType: Any.Type { get }
	static var valueType: Any.Type { get }
	static func emptyValue() -> Any
}

extension Dictionary: AnyDictionarySchema {

	static var keyType: Any.Type {
		Key.self
	}

	static var valueType: Any.Type {
		Value.self
	}

	static func emptyValue() -> Any {
		Self()
	}
}

private enum PropertySchemaError: Error {

	case recursiveType
}

private extension OrderedDictionary where Key == String, Value == ReferenceOr<SchemaObject> {

	func hasMoreCompleteObjects(
		than other: ComponentsMap<SchemaObject>,
		baseline: ComponentsMap<SchemaObject>
	) -> Bool {
		for (key, schema) in self where baseline[key] == nil {
			let properties = schema.object?.schemaInferenceObjectProperties ?? []
			let otherProperties = other[key]?.object?.schemaInferenceObjectProperties ?? []
			if properties.count > otherProperties.count, properties.isSuperset(of: otherProperties) {
				return true
			}
		}
		return false
	}
}

private extension SchemaObject {

	var schemaInferenceObjectProperties: Set<String> {
		guard case let .object(context) = context else {
			return []
		}
		return Set(context.properties?.keys ?? [])
	}

	var isSchemaInferenceReferenceable: Bool {
		if self.enum?.isEmpty == false {
			return true
		}

		switch context {
		case .composition:
			return true
		case let .object(context):
			switch context.additionalProperties {
			case .none:
				return true
			case let .boolean(value):
				return !value
			case .schema:
				return false
			}
		default:
			return false
		}
	}
}

private extension String {

	static func schemaInferenceTypeName(_ type: Any.Type) -> String {
		String(reflecting: type)
			.components(separatedBy: ["<", ",", " ", ">", ":", "[", "]", "?"])
			.lazy
			.flatMap { component in
				var result = component.components(separatedBy: ["."])
				if result.count > 1 {
					result.removeFirst()
				}
				return result
			}
			.flatMap {
				$0.components(separatedBy: .alphanumerics.inverted)
			}
			.joined()
	}
}

private extension Collection {

	var firstValue: Element? {
		guard !isEmpty else {
			return nil
		}
		return self[startIndex]
	}
}
