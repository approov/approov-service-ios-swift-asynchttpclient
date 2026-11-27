// MIT License
//
// Copyright (c) 2016-present, Critical Blue Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

// ApproovRequestPathError creates the errors that a request fails with on the request path, other than the
// standard decisions, which keep their ApproovError. Each one is a URLError, the platform network error, so
// that the app's error handling sees an ordinary network failure.
enum ApproovRequestPathError {
    /// The error for a configuration error of the app, such as a required body digest that cannot be
    /// generated. It is logged. The message never quotes a value that could be a token or a secure string.
    static func configuration(_ message: String) -> URLError {
        ApproovService.log(.error, "ApproovService: " + message)
        return URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "ApproovService: " + message])
    }

    /// The error for a value from the Approov SDK, such as a token, that a header cannot carry. The header is
    /// named, never the value.
    static func sdkValue(_ what: String, header: String) -> URLError {
        return configuration("Approov header \(header): invalid character in SDK \(what)")
    }

    /// The error for an error from a service mutator hook that is neither a URL loading error nor a standard
    /// decision. It is logged naming the hook, and the original error is the underlying error.
    static func hookFailure(_ hook: String, _ error: Error) -> URLError {
        let message = "ApproovServiceMutator.\(hook) failed: \(error.localizedDescription)"
        ApproovService.log(.error, "ApproovService: " + message)
        return URLError(.unknown, userInfo: [NSLocalizedDescriptionKey: "ApproovService: " + message,
                                             NSUnderlyingErrorKey: error as NSError])
    }

    /// Calls a service mutator hook on the request path. A URL loading error is the app's own abort and is
    /// thrown unchanged, as is a standard decision made during the call. Any other error, an ApproovError
    /// the app's own code threw included, is thrown as a hookFailure.
    static func callHook<T>(_ hook: String, _ call: () throws -> T) throws -> T {
        return try callHook(hook, call, standardDecision: { throw $0 })
    }

    /// Calls a hook as callHook does, but ignores a standard decision, for a request where the standard
    /// decisions do not apply (a failure status for a host that is not listed).
    static func callHookIgnoringStandardDecisions<T>(_ hook: String, _ call: () throws -> T) throws -> T? {
        return try callHook(hook, { try call() as T? }, standardDecision: { _ in nil })
    }

    private static func callHook<T>(_ hook: String, _ call: () throws -> T,
                                    standardDecision: (ApproovError) throws -> T) throws -> T {
        let decisions = ApproovStandardDecisions()
        do {
            return try ApproovStandardDecisions.withCurrent(decisions, call)
        } catch let approovError as ApproovError {
            if decisions.contains(approovError) {
                return try standardDecision(approovError)
            }
            throw hookFailure(hook, approovError)
        } catch {
            if (error as NSError).domain == NSURLErrorDomain {
                throw error
            }
            throw hookFailure(hook, error)
        }
    }
}

// ApproovStandardDecisions records the errors that the standard decisions throw during one hook call, so that
// they are told apart from an error the app's own code threw, also when a custom mutator inherits or calls
// them. Hooks run synchronously inside updateRequestWithApproov, so the record is kept per thread.
final class ApproovStandardDecisions {
    private static let key = "io.approov.service.asynchttpclient.ApproovStandardDecisions"
    private let lock = NSLock()
    private var made: [String] = []

    /// Runs a hook call with this record as the current one on this thread.
    static func withCurrent<T>(_ decisions: ApproovStandardDecisions, _ call: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = decisions
        defer { dictionary[key] = previous }
        return try call()
    }

    /// Records an error as a standard decision of the current hook call, and returns it to be thrown.
    static func made(_ error: ApproovError) -> ApproovError {
        (Thread.current.threadDictionary[key] as? ApproovStandardDecisions)?.record(error)
        return error
    }

    private func record(_ error: ApproovError) {
        lock.lock()
        defer { lock.unlock() }
        made.append(String(reflecting: error))
    }

    /// True if the error is one of the standard decisions of this call, with the same case and values.
    func contains(_ error: ApproovError) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return made.contains(String(reflecting: error))
    }
}
