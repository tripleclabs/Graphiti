import GraphQL

/// A DSL component that can carry directives applied to its schema location.
///
/// The modifier lives in a protocol extension so that the five independent
/// component hierarchies do not each need their own copy.
public protocol DirectiveAnnotatable: AnyObject {
    var appliedDirectives: [AppliedDirective] { get set }
}

public extension DirectiveAnnotatable {
    /// Apply a directive to this schema location.
    ///
    /// The directive must be declared with a `Directive` component in the same
    /// schema, or schema construction throws. Argument values are rendered
    /// against the declared argument types, so a string passed to an enum-typed
    /// argument prints unquoted.
    ///
    /// - Parameters:
    ///   - name: The directive name, without the leading `@`.
    ///   - arguments: Ordered name/value pairs. Order is preserved in the
    ///     emitted SDL so output is byte-stable across builds.
    @discardableResult
    func directive(_ name: String, _ arguments: (String, Map)...) -> Self {
        appliedDirectives.append(AppliedDirective(name: name, arguments: arguments))
        return self
    }
}
