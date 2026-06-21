# Agent Memory: DTO Inference Limitation

## Context

Drinklet (`/Users/kkiermasz/drinklet-server`) uses `VaporToOpenAPI` to generate a public OpenAPI 3.0.1 document from Vapor routes. Most DTOs can be documented with route metadata like:

```swift
response: .type([SomeDTO].self)
```

During the Drinklet OpenAPI integration, one DTO shape did not infer correctly and required an explicit `OpenAPIType.openAPISchema` workaround.

## Observed Issue

Automatic schema generation missed a real property on a DTO that contains a dictionary of associated-value enum values.

Reduced shape from Drinklet:

```swift
struct CocktailDTO: Content {
    let id: UUID
    let name: String
    let amounts: [String: AmountDTO]
    let tintColor: String?
}

enum AmountDTO: Content {
    case volume(imperial: Double, metric: Double, parts: Double, id: UUID)
    case special(value: Double, unit: SpecialUnitDTO, id: UUID)
    case constant(value: String, id: UUID)
}

enum SpecialUnitDTO: String, Content, CaseIterable {
    case wedge
    case dash
    case barspoon
    case invalid
}
```

Expected:

- `response: .type([CocktailDTO].self)` should include all public DTO fields in the generated schema.
- The generated cocktail schema should include `tintColor`.
- The `amounts` value schema should represent `AmountDTO` cases, ideally as `oneOf`.

Actual:

- Automatic schema generation omitted `tintColor` from `CocktailDTO`.
- `AmountDTO` could not be represented correctly without an explicit `OpenAPIType` schema.
- Drinklet worked around this by making both `AmountDTO` and `CocktailDTO` conform to `OpenAPIType`, even though only the associated-value enum should ideally require custom handling.

## Suspected Cause

The current inference path is decoder/encoder based rather than true compile-time reflection. Check:

- `SwiftOpenAPI/Sources/SwiftOpenAPI/Encoders/TypeRevision/TypeRevisionDecoder.swift`
- `SwiftOpenAPI/Sources/SwiftOpenAPI/Encoders/SchemeEncoder.swift`
- `VaporToOpenAPI/Sources/VaporToOpenAPI/OpenAPIValue.swift`

The decoder-based type walk appears fragile around nested dictionaries whose value type is an associated-value enum. In Drinklet, the property after `amounts` was not emitted in the inferred object schema.

## Desired Library Fix

Add regression coverage for a `Codable`/`Content` struct with:

- ordinary scalar fields,
- an optional field after a dictionary property,
- a dictionary value type that is an associated-value enum,
- raw-value `CaseIterable` nested enums.

Then improve schema inference so a parent DTO schema remains complete even when a nested property type cannot be fully inferred automatically. At minimum, failure to infer a nested property should not cause later sibling properties to disappear.

An ideal fix would also generate a reasonable `oneOf` for Swift associated-value enums matching Swift's synthesized Codable wire shape.

## Drinklet Workaround To Remove Later

Once this fork fixes the inference issue and Drinklet updates to that fixed version:

- Remove explicit `OpenAPIType` conformance from `CocktailDTO` if `response: .type([CocktailDTO].self)` includes `tintColor` and all other fields automatically.
- Keep or remove `AmountDTO.openAPISchema` based on whether associated-value enum inference is fixed.
- Update Drinklet `AGENTS.md` and `docs/openapi.md` to remove or soften the workaround guidance.
- Keep Drinklet `OpenAPIRoutesTests` assertions that verify generated schema correctness.
