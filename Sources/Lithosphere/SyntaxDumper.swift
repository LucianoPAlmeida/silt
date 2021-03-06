/// SyntaxDumper.swift
///
/// Copyright 2017-2018, The Silt Language Project.
///
/// This project is released under the MIT license, a copy of which is
/// available in the repository.

import Foundation
import Rainbow

public class SyntaxDumper<StreamType: TextOutputStream>: Writer<StreamType> {
  public func writeLoc(_ loc: SourceLocation?) {
    if let loc = loc {
      let url = URL(fileURLWithPath: loc.file)
      write(" ")
      write(url.lastPathComponent.yellow)
      write(":")
      write("\(loc.line)".cyan)
      write(":")
      write("\(loc.column)".cyan)
    }
  }

  public func dump(_ node: Syntax, root: Bool = true) {
    write("(")
    switch node {
    case let node as TokenSyntax:
      switch node.tokenKind {
      case .identifier(let name):
        write("identifier".green.bold)
        write(" \"\(name)\"".red)
      default:
        write("\(node.tokenKind)".green.bold)
      }
      writeLoc(node.startLoc)
    default:
      write("\(node.raw.kind)".magenta.bold)
      writeLoc(node.startLoc)
      withIndent {
        for child in node.children {
          writeLine()
          dump(child, root: false)
        }
      }
    }
    write(")")
    if root {
      writeLine()
    }
  }
}
