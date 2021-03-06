/// Type.swift
///
/// Copyright 2017-2018, The Silt Language Project.
///
/// This project is released under the MIT license, a copy of which is
/// available in the repository.

import Lithosphere

public struct NameAndType: Hashable {
  public let name: String
  public unowned let type: GIRType

  public static func == (lhs: NameAndType, rhs: NameAndType) -> Bool {
    return lhs.name == rhs.name && lhs.type === rhs.type
  }

  public var hashValue: Int {
    return name.hashValue ^ ObjectIdentifier(type).hashValue
  }
}

public protocol TypeVisitor {
  func visitGIRExprType(_ type: GIRExprType)
  func visitTypeMetadataType(_ type: TypeMetadataType)
  func visitTypeType(_ type: TypeType)
  func visitArchetypeType(_ type: ArchetypeType)
  func visitParameterizedType(_ type: ParameterizedType)
  func visitTupleType(_ type: TupleType)
  func visitDataType(_ type: DataType)
  func visitRecordType(_ type: RecordType)
  func visitFunctionType(_ type: FunctionType)
  func visitSubstitutedType(_ type: SubstitutedType)
  func visitBoxType(_ type: BoxType)
  func visitBottomType(_ type: BottomType)
}

extension TypeVisitor {
  public func visitType(_ value: Value) {
    switch value {
    case let type as DataType:
      return self.visitDataType(type)
    case let type as RecordType:
      return self.visitRecordType(type)
    case let type as ArchetypeType:
      return self.visitArchetypeType(type)
    case let type as SubstitutedType:
      return self.visitSubstitutedType(type)
    case let type as FunctionType:
      return self.visitFunctionType(type)
    case let type as TypeMetadataType:
      return self.visitTypeMetadataType(type)
    case let type as TypeType:
      return self.visitTypeType(type)
    case let type as BottomType:
      return self.visitBottomType(type)
    case let type as GIRExprType:
      return self.visitGIRExprType(type)
    case let type as TupleType:
      return self.visitTupleType(type)
    case let type as BoxType:
      return self.visitBoxType(type)
    default:
      fatalError("attempt to serialize unknown value \(value)")
    }
  }
}

// FIXME: Temporary
public final class GIRExprType: GIRType {
  public let expr: ExprSyntax
  public init(_ expr: ExprSyntax) {
    self.expr = expr
    super.init(name: "", type: TypeType.shared, category: .object)
  }
}

public final class TypeMetadataType: GIRType {
  init() {
    super.init(name: "", type: TypeType.shared, category: .address)
  }
  public override func equals(_ other: Value) -> Bool {
    return other is TypeMetadataType
  }
  public override var hashValue: Int {
    return 0
  }
}

public final class TypeType: GIRType {
  static let shared = TypeType()

  init() {
    let typeType =
      /// HACK: This only exists to appease the typechecker.
      unsafeBitCast(nil as TypeType?, to: TypeType.self)
    super.init(name: "", type: typeType, category: .address)
  }

  public override var type: Value {
    get { return self }
    set { /* do nothing */ }
  }

  public override func equals(_ other: Value) -> Bool {
    return other is TypeType
  }

  public override var hashValue: Int {
    return 0
  }
}

public final class ArchetypeType: GIRType {
  public let index: Int

  public init(index: Int) {
    self.index = index
    super.init(name: "τ_\(index)", type: TypeType.shared, category: .address)
  }

  public override func equals(_ other: Value) -> Bool {
    guard let other = other as? ArchetypeType else { return false }
    return index == other.index
  }

  public override var hashValue: Int {
    return index.hashValue ^ 0x374b2947
  }
}

public class ParameterizedType: GIRType {
  public struct Parameter: Hashable {
    public /*owned */let archetype: ArchetypeType
    let value: NameAndType

    public static func == (lhs: Parameter, rhs: Parameter) -> Bool {
      return lhs.archetype == rhs.archetype && lhs.value == rhs.value
    }

    public var hashValue: Int {
      return archetype.hashValue ^ value.hashValue ^ 0x432fba397
    }
  }
  public private(set) var parameters = [Parameter]()
  public private(set) var substitutions = Set<SubstitutedType>()

  init(name: String, indices: GIRType, category: Value.Category) {
    super.init(name: name, type: indices, category: category)
  }

  public func addParameter(name: String, type: GIRType) {
    let archetype = ArchetypeType(index: parameters.count)
    let value = NameAndType(name: name, type: type)
    parameters.append(Parameter(archetype: archetype, value: value))
  }

  private func ensureValidIndex(_ index: Int) {
    guard index < parameters.count else {
      fatalError("""
                 attempt to use archetype at index \(index) for \
                 type with \(parameters.count) archetypes
                 """)
    }
  }

  public func substituted(
    _ substitutions: [GIRType: GIRType]) -> SubstitutedType {
    let subst = SubstitutedType(substitutee: self, substitutions: substitutions)
    return self.substitutions.getOrInsert(subst)
  }

  public func archetype(at index: Int) -> ArchetypeType {
    ensureValidIndex(index)
    return parameters[index].archetype
  }

  public func parameter(at index: Int) -> NameAndType {
    ensureValidIndex(index)
    return parameters[index].value
  }
}

public final class TupleType: ParameterizedType {
  public let elements: [GIRType]

  init(elements: [GIRType], category: Value.Category) {
    self.elements = elements
    super.init(name: "", indices: TypeType.shared, category: category)
  }

  public override func equals(_ other: Value) -> Bool {
    guard let other = other as? TupleType else { return false }
    return elements == other.elements
  }

  public override var hashValue: Int {
    return self.elements.reduce(0) { $0 ^ $1.hashValue }
  }
}

public final class DataType: ParameterizedType {
  public typealias Constructor = (name: String, payload: TupleType?)
  public private(set) var constructors = [Constructor]()

  public func addConstructors(_ array: [Constructor]) {
    constructors.append(contentsOf: array)
  }

  public override func equals(_ other: Value) -> Bool {
    guard let other = other as? DataType else { return false }
    return name == other.name &&
           parameters == other.parameters
  }

  public override var hashValue: Int {
    var h = name.hashValue
    for param in parameters {
      h ^= param.hashValue
    }
    for constr in constructors {
      h ^= constr.0.hashValue
    }
    return h
  }
}

public typealias GIRType = Value

public final class RecordType: ParameterizedType {
  public typealias Field = NameAndType
  public private(set) var fields = [Field]()

  public func addField(name: String, type: GIRType) {
    fields.append(Field(name: name, type: type))
  }

  public override func equals(_ other: Value) -> Bool {
    guard let other = other as? RecordType else { return false }
    return name == other.name &&
           fields == other.fields &&
           parameters == other.parameters
  }

  public override var hashValue: Int {
    var h = name.hashValue
    for field in fields {
      h ^= field.hashValue
    }
    for param in parameters {
      h ^= param.hashValue
    }
    return h
  }
}

public final class FunctionType: GIRType {
  public let arguments: UnownedArray<GIRType>
  public unowned let returnType: GIRType

  init(arguments: [GIRType], returnType: GIRType) {
    self.arguments = UnownedArray(values: arguments)
    self.returnType = returnType
    super.init(name: "", type: TypeType.shared, category: returnType.category)
  }

  public override func equals(_ other: Value) -> Bool {
    guard let other = other as? FunctionType else { return false }
    return returnType === other.returnType && arguments == other.arguments
  }

  public override var hashValue: Int {
    return returnType.hashValue ^ arguments.hashValue
  }
}

public final class SubstitutedType: GIRType {
  public unowned let substitutee: ParameterizedType
  public let substitutions: UnownedDictionary<GIRType, GIRType>

  init(substitutee: ParameterizedType, substitutions: [GIRType: GIRType]) {
    self.substitutee = substitutee
    self.substitutions = UnownedDictionary(substitutions)
    super.init(name: "", type: TypeType.shared, category: substitutee.category)
  }

  public override func equals(_ other: Value) -> Bool {
    guard let other = other as? SubstitutedType else { return false }
    return substitutee == other.substitutee &&
           substitutions == other.substitutions
  }

  public override var hashValue: Int {
    return substitutee.hashValue ^ substitutions.hashValue
  }
}

public final class BoxType: ParameterizedType {
  let payloadTypeName: String

  init(_ name: String) {
    self.payloadTypeName = name
    super.init(name: "@box " + name,
               indices: TypeType.shared, category: .object)
  }

  public override func equals(_ other: Value) -> Bool {
    guard let other = other as? BoxType else { return false }
    return name == other.name &&
      parameters == other.parameters
  }

  public override var hashValue: Int {
    var h = name.hashValue
    for param in parameters {
      h ^= param.hashValue
    }
    return h
  }
}

public final class BottomType: GIRType {
  public static let shared = BottomType()

  init() {
    super.init(name: "", type: TypeType.shared, category: .object)
  }

  public override var type: Value {
    get { return self }
    set { /* do nothing */ }
  }

  public override func equals(_ other: Value) -> Bool {
    return other is BottomType
  }

  public override var hashValue: Int {
    return 0
  }
}
