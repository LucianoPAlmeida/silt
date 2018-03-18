/// Patterns.swift
///
/// Copyright 2018, The Silt Language Project.
///
/// This project is released under the MIT license, a copy of which is
/// available in the repository.

import Lithosphere
import Moho
import Mantle
import Seismography

/// To compile pattern matching, we employ a slightly modified copy of the
/// algorithm and heuristics in Maranget's [Compiling Pattern Matching to Good
/// Decision Trees](http://moscova.inria.fr/~maranget/papers/ml05e-maranget.pdf)
///
/// Consider, as Luc does, the following types and function:
///
///     data Bool : Type where
///       tt : Bool
///       ff : Bool
///
///     data Index : Type where
///       one : Index
///       two : Index
///       three : Index
///       four : Index
///
///     maranget : Bool -> Bool -> Bool -> Index
///     maranget _  ff tt = one
///     maranget ff tt _  = two
///     maranget _  _  ff = three
///     maranget _  _  tt = four
///
/// It is clear that we could naively compile a branch tree that checks each
/// condition in turn and let the optimizer clean up after us.  This requires
/// emitting O(n)-many compares, at least n-3 of which will be bogus.
/// Maranget's algorithm allows us to express this in just 4 compares.
///
/// We define the clause matrix of the above function by adjoining the pattern
/// matrix and the clause bodies:
///
///                            | _  ff tt -> one   |
///     P = (Clauses:Bodies) = | ff tt _  -> two   |
///                            | _  _  ff -> three |
///                            | _  _  tt -> four  |
///
/// The algorithm proceeds by recursive *specialization* of the pattern matrix:
///   0) If the pattern matrix is just a pattern row vector of irrefutable
///      patterns, then specialization is finished and we emit the clause body
///      into the current continuation.
///   1) Else we first score each "column vector" of patterns.  Note that it is
///      possible to define a function with fewer patterns than arguments.  In
///      such a case, we emit dummy wildcard patterns.
///   2) The column with the highest score is the one most deserving of our
///      attention.  We focus on it.
///   3) We then walk the column and assign each clause headed by a constructor
///      form at each index to a bucket of similarly-headed clauses.
///   4) For each such bucket, we create a `switch_constr` and specialize the
///      list of patterns in each bucket into its corresponding child
///      continuation.  Before recurring, we note that the column has already
///      been specialized so the scoring algorithm doesn't pick it up again.
///
/// Thus, we score columns and note that column 1 is most pressing.  We
/// specialize on the value `ff` and come up with this matrix and a
/// corresponding unspecialized matrix:
///
///
///     P' = | _ tt -> one |
///
///            | ff tt _  -> two   |
///     Pdef = | _  _  ff -> three |
///            | _  _  tt -> four  |
///
/// Applying one more step, we re-score and select column 2 in P'.  This time,
/// our specialization yields a row vector containing only irrefutable patterns:
///
///     P'' = | _ -> one |
///
/// Thus, we're done.  Specialization of `Pdef` proceeds similarly.
///
/// Wildcards and constructor arguments introduce a number of caveats into this
/// explanation.  See the specialization and scoring functions.
extension GIRGenFunction {
  func emitPatternMatrix(_ matrix: [Clause],
                         _ params: [Value], _ returnCont: Value) {
    guard let firstRow = matrix.first else {
      // If the pattern matrix is empty, emit `unreachable` and bail.
      _ = self.B.createUnreachable(self.f)
      return
    }

    guard !firstRow.patterns.isEmpty && !params.isEmpty else {
      // If there are no patterns and no parameters we have a matrix of zero
      // width - a constant.  Emit the body and bail.
      guard let body = firstRow.body else {
        _ = self.B.createUnreachable(self.f)
        return
      }
      let (newParent, RV) = self.emitRValue(self.f, body)
      _ = self.B.createApply(newParent, returnCont, [RV])
      return
    }

    // We're in business, start specializing.
    var unspecialized = Set<Int>(0..<params.count)
    self.stepSpecialization(self.f, matrix, params, returnCont, &unspecialized)
  }

  /// Specialize a pattern matrix into a particular continuation.
  private func stepSpecialization(
    _ root: Continuation, _ matrix: [Clause], _ params: [Value],
    _ returnCont: Value, _ unspecialized: inout Set<Int>) {
    // If the pattern matrix turns out to be a pattern row vector, we're done.
    if
      matrix.count == 1,
      let vars = allIrrefutable(matrix[0].patterns, unspecialized)
    {
      // Wire up unspecialized (and hence, variable) patterns to their
      // corresponding (R)Values.
      for (idx, v) in vars.enumerated() {
        guard unspecialized.contains(idx) else { continue }
        self.varLocs[v.name] = params[idx]
      }
      // Emit the clause's body.
      guard let body = matrix[0].body else {
        _ = self.B.createUnreachable(self.f)
        return
      }
      self.emitFinalColumnBody(root, returnCont, body)
      return
    }

    // Score the column of the pattern matrix and extract the necessary column.
    let necessity = scoreColumns(matrix, params.count, unspecialized)
    let colIdx = necessity.column

    // If we're down to a singular unspecialized row vector then we can emit the
    // final column in-line.  Note that pattern matrices are never empty.
    if unspecialized.count == 1 {
      return self.emitFinalColumn(root, colIdx, params[colIdx],
                                  returnCont, matrix)
    }

    var specializationTable = [String: [Clause]]()
    var switchNest = [(String, Value)]()
    var destMap = [(String, Continuation)]()
    var headsUnderDefaultsMatrix = [Clause]()
    var defaultsMatrix = [Clause]()
    var defaultInfo: (cont: Continuation, ref: Value)? = nil
    for (idx, clause) in matrix.enumerated() {
      // Grab the pattern at the neessary column, substituting a wildcard if
      // necessary.
      let pat = colIdx < clause.patterns.count
              ? clause.patterns[colIdx]
              : Pattern.variable(Var(wildcardName, 0))
      switch pat {
      case .absurd:
        fatalError("Absurd patterns should have been handled by now!")
      case let .constructor(name, args):
        // N.B. If we're specializing a column with wildcards under the first
        // pattern, we need to make sure we don't create a specialization
        // beyond the first head.  All other clauses go to the default matrix.
        if necessity.hasWildcards && !specializationTable.isEmpty {
          headsUnderDefaultsMatrix.append(clause)
          continue
        }

        let specKey = name.key.string
        if specializationTable[specKey] == nil {
          // Setup a unique BB-like continuation to jump to for this case.
          let destBB = self.B.buildContinuation(
                          name: root.name + "#col\(colIdx)row\(idx)")
          let ref = self.B.createFunctionRef(destBB)
          // Register the continuation in the destination map and a
          // `function_ref` pointing at it in the switch nest.
          destMap.append((specKey, destBB))
          switchNest.append((specKey, ref))
          for _ in args {
            _ = destBB.appendParameter(type: BottomType.shared)
          }
        }

        // Specialize the clause's pattern vector and flatten any incoming
        // arguments.
        //
        // LEMMA 1: For any constructor `c`, the following equivalence holds:
        //
        //     Match[(c(w1,...,wa) v2 ··· vn), P → A]   = k
        //                         ⇕
        //     Match[(w1 ··· wa v2 ··· vn), S(c,P → A)] = k
        //
        // We make a corresponding change to the parameter vector later as we
        // specialize the matrix so we can rewire arguments properly.
        let specialClause = clause.bySpecializing(column: colIdx,
                                                  patterns: args)
        specializationTable[specKey, default: []].append(specialClause)
      case .variable(_):
        if defaultInfo == nil {
          // Setup a unique BB-like continuation for the default block.
          let defaultDestBB = self.B.buildContinuation(
                                name: root.name + "#default")
          let defaultRef = self.B.createFunctionRef(defaultDestBB)
          defaultInfo = (cont: defaultDestBB, ref: defaultRef)
        }
        defaultsMatrix.append(clause)
      }
    }

    // Emit a branch in the decision tree for all nodes we've seen.
    _ = self.B.createSwitchConstr(root, params[colIdx],
                                  switchNest, defaultInfo?.ref)
    // N.B. Having wildcards in the column implies we've only got only one thing
    // to specialize and a rather large default matrix...
    assert(!necessity.hasWildcards || destMap.count == 1)
    for (key, dest) in destMap {
      guard var specializedMatrix = specializationTable[key] else {
        fatalError("Wired a destination without any specializations?")
      }

      // If we've got at least one wildcard pattern in this column, we have to
      // take one of them along for the ride as a default pattern for the
      // specialized matrix.  Any will do, we pick the first to maintain
      // source-order.
      if necessity.hasWildcards && !headsUnderDefaultsMatrix.isEmpty {
        specializedMatrix.append(defaultsMatrix[0])
      }

      var parameters = params
      if dest.parameters.isEmpty {
        // No parameters to unpack, no problem.  Specialize the column.
        unspecialized.remove(colIdx)
      } else {
        // Fix the flattened parameters in place of the specialized constructor
        // head at this column so the specialized matrix can wire up its
        // arguments properly when it emits its body.
        //
        // FIXME: Generalize to n-many arguments by performing something that
        // looks damn closed to a weakning on the unspecialized set.
        assert(dest.parameters.count == 1) // FIXME: For now.
        parameters.remove(at: colIdx)
        parameters.insert(contentsOf: dest.parameters as [Value], at: colIdx)
      }
      // Recur and specialize on this constructor head.
      self.stepSpecialization(dest, specializedMatrix, parameters,
                              returnCont, &unspecialized)
      unspecialized.insert(colIdx)
    }

    // Handle defaults:
    if let (defaultDest, _) = defaultInfo {
      unspecialized.remove(colIdx)
      self.stepSpecialization(defaultDest,
                              headsUnderDefaultsMatrix + defaultsMatrix,
                              params, returnCont, &unspecialized)
      unspecialized.insert(colIdx)
    }
  }

  private func emitFinalColumn(
    _ parent: Continuation, _ colIdx: Int,
    _ param: Value, _ retParam: Value, _ matrix: [Clause]
  ) {
    var dests = [(String, Value)]()
    for (idx, clause) in matrix.enumerated() {
      guard let body = clause.body else {
        fatalError()
      }

      let pat = colIdx < clause.patterns.count
        ? clause.patterns[colIdx]
        : Pattern.variable(Var(wildcardName, 0))
      switch pat {
      case .absurd:
        fatalError()
      case let .variable(v):
        assert(matrix.count == 1)
        self.varLocs[v.name] = param
        self.emitFinalColumnBody(parent, retParam, body)
        self.varLocs[v.name] = nil
        return
      case let .constructor(name, pats):
        let destBB = self.B.buildContinuation(
                      name: parent.name + "#col\(colIdx)row\(idx)")
        let destRef = self.B.createFunctionRef(destBB)
        //        assert(allIrrefutable(pats) != nil)
        for _ in pats {
          destBB.appendParameter(type: BottomType.shared, ownership: .owned)
        }
        self.emitFinalColumnBody(destBB, retParam, body)
        dests.append((name.key.string, destRef))
      }
    }
    _ = self.B.createSwitchConstr(parent, param, dests)
  }

  private func emitFinalColumnBody(_ bb: Continuation, _ retParam: Value,
                                   _ body: Term<TT>) {
    switch body {
    case let .constructor(name, args):
      guard !args.isEmpty else {
        let retVal = self.B.createDataInit(name.key.string, [])
        _ = self.B.createApply(bb, retParam, [retVal])
        return
      }
      let (newParent, bodyVal) = self.emitRValue(bb, body)
      _ = self.B.createApply(newParent, retParam, [bodyVal])
    case let .apply(head, args):
      switch head {
      case .definition(_):
        fatalError()
      case let .meta(mv):
        guard let bind = self.tc.signature.lookupMetaBinding(mv) else {
          fatalError()
        }
        self.emitFinalColumnBody(bb, retParam, self.tc.toNormalForm(bind.body))
      case let .variable(v):
        guard let varLoc = self.varLocs[v.name] else {
          fatalError()
        }
        _ = self.B.createApply(bb, retParam, [varLoc])
      }
    default:
      fatalError()
    }
  }

  private struct Necessity {
    let column: Int
    let hasWildcards: Bool
  }

  /// Scores a pattern matrix and returns information about the necessity of
  /// its column vectors.
  ///
  /// The necessity of a column is computed by walking it and giving it a
  /// positive score every time it contains a constructor pattern that is not
  /// underneath a wildcard pattern.  The column with the highest score is
  /// selected as the necessary column.
  ///
  /// FIXME: There are probably more creative ways of computing this for
  /// sub-matrices by slicing a score vector using the unspecialized column set.
  private func scoreColumns(
    _ pm: [Clause], _ maxWidth: Int, _ keep: Set<Int>
  ) -> Necessity {
    assert(!pm.isEmpty)

    var scoreMatrix = [(Int, Int)]()
    scoreMatrix.reserveCapacity(maxWidth)
    for i in 0..<maxWidth {
      scoreMatrix.append((i, 0))
    }

    var wildcardColumns = Set<Int>()
    for j in 0..<pm.count {
      for i in 0..<maxWidth {
        guard keep.contains(i) else {
          // Heavily penalize columns we've already specialized.
          scoreMatrix[i].1 = Int.min
          continue
        }

        // Columns containing wildcards have a fixed score.
        guard !wildcardColumns.contains(i) else { continue }

        let clause = pm[j]
        guard i < clause.patterns.count else {
          wildcardColumns.insert(i)
          continue
        }

        switch clause.patterns[i] {
        case .absurd:
          fatalError()
        case .variable(_):
          // Note this column as containing a wildcard so we don't increase its
          // score of the column any further.
          wildcardColumns.insert(i)
          continue
        case .constructor(_, _):
          scoreMatrix[i].1 += 1
        }
      }
    }

    guard let sortedScores = scoreMatrix.max(by: { (lhs, rhs) -> Bool in
      return lhs.1 < rhs.1
    }) else {
      fatalError("Score matrix can never be empty!!")
    }
    return Necessity(column: sortedScores.0,
                     hasWildcards: wildcardColumns.contains(sortedScores.0))
  }

  /// Computes and returns a list of all variables bound by the pattern
  /// according to a mask.  If the pattern list contains a non-variable pattern
  /// `nil` is returned.
  private func allIrrefutable(
    _ patterns: [Pattern], _ mask: Set<Int>) -> [Var]? {
    var result = [Var]()
    result.reserveCapacity(patterns.count)
    for (idx, pattern) in patterns.enumerated() {
      guard mask.contains(idx) else {
        result.append(Var(wildcardName, 0))
        continue
      }

      if case .absurd = pattern {
        continue
      }

      guard case let .variable(v) = pattern else {
        return nil
      }
      result.append(v)
    }
    return result
  }

  var wildcardToken: TokenSyntax {
    return TokenSyntax.implicit(.underscore)
  }

  var wildcardName: Name {
    return Name(name: wildcardToken)
  }
}