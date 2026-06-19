// Harness.swift — a tiny dependency-free assertion runner.
//
// XCTest and swift-testing ship only with full Xcode; this project must build
// and test under the Command Line Tools alone. So checks run as a normal
// executable: accumulate failures, print a summary, exit non-zero if any fail.

import Foundation

final class Check {
    private var failures = 0
    private var total = 0

    func expect(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
        total += 1
        if !cond {
            failures += 1
            FileHandle.standardError.write(Data("FAIL [\(file):\(line)] \(msg)\n".utf8))
        }
    }

    func eq<T: Equatable>(_ a: T, _ b: T, _ label: String = "", file: StaticString = #file, line: UInt = #line) {
        expect(a == b, "\(label) — expected \(b), got \(a)", file: file, line: line)
    }

    func summary() -> Never {
        if failures == 0 {
            print("ok — \(total) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("FAILED — \(failures)/\(total) checks failed\n".utf8))
        exit(1)
    }
}
