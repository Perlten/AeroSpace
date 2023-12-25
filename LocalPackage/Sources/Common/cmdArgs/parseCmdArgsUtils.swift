public protocol RawCmdArgs: Copyable {
    init()
    static var parser: CmdParser<Self> { get }
}

public extension RawCmdArgs {
    static var info: CmdStaticInfo { Self.parser.info }

    func getOptionWithDefault<K>(_ path: KeyPath<Self, K?>) -> K {
        // If Swift had covariant / contravariant generics, I'd not need this runtime check
        self[keyPath: path] ?? errorT("\(path) must provide a default value")
    }
}

public protocol CmdArgs {
    static var info: CmdStaticInfo { get }
}

public struct CmdParser<T : Copyable> {
    let info: CmdStaticInfo
    let options: [String: any ArgParserProtocol<T>]
    let arguments: [any ArgParserProtocol<T>]
}

public func cmdParser<T>(
    kind: CmdKind,
    allowInConfig: Bool,
    help: String,
    options: [String: any ArgParserProtocol<T>],
    arguments: [any ArgParserProtocol<T>]
) -> CmdParser<T> {
    CmdParser(
        info: CmdStaticInfo(help: help, kind: kind, allowInConfig: allowInConfig),
        options: options,
        arguments: arguments
    )
}

public struct CmdStaticInfo: Equatable {
    public let help: String
    public let kind: CmdKind
    public let allowInConfig: Bool

    public init(
        help: String,
        kind: CmdKind,
        allowInConfig: Bool
    ) {
        self.help = help
        self.kind = kind
        self.allowInConfig = allowInConfig
    }
}

public enum ParsedCmd<T> {
    case cmd(T)
    case help(String)
    case failure(String)

    public func map<R>(_ mapper: (T) -> R) -> ParsedCmd<R> {
        flatMap { .cmd(mapper($0)) }
    }

    public func flatMap<R>(_ mapper: (T) -> ParsedCmd<R>) -> ParsedCmd<R> {
        switch self {
        case .cmd(let cmd):
            return mapper(cmd)
        case .help(let help):
            return .help(help)
        case .failure(let fail):
            return .failure(fail)
        }
    }

    public func unwrap() -> (T?, String?, String?) {
        var command: T? = nil
        var error: String? = nil
        var help: String? = nil
        switch self {
        case .cmd(let _command):
            command = _command
        case .help(let _help):
            help = _help
        case .failure(let _error):
            error = _error
        }
        return (command, help, error)
    }
}

public func parseRawCmdArgs<T : RawCmdArgs>(_ raw: T, _ args: [String]) -> ParsedCmd<T> {
    var args = args
    var raw = raw
    var errors: [String] = []

    var argumentIndex = 0
    var options: Set<String> = Set()

    while !args.isEmpty {
        let arg = args.next()
        if arg == "-h" || arg == "--help" {
            return .help(T.info.help)
        } else if let optionParser: any ArgParserProtocol<T> = T.parser.options[arg] {
            if !options.insert(arg).inserted {
                errors.append("Duplicated option '\(arg)'")
            }
            raw = optionParser.transformRaw(raw, arg, &args, &errors)
        } else if let parser = T.parser.arguments.getOrNil(atIndex: argumentIndex) {
            raw = parser.transformRaw(raw, arg, &args, &errors)
            argumentIndex += 1
        } else {
            errors.append("Unknown argument '\(arg)'")
            break
        }
    }

    return errors.isEmpty ? .cmd(raw) : .failure(errors.joinErrors())
}

public extension [String] {
    func joinErrors() -> String { // todo reuse in config parsing?
        map { (error: String) -> String in
            error.split(separator: "\n").enumerated()
                .map { (i, line) in
                    i == 0
                        ? "ERROR: " + line
                        : "       " + line
                }
                .joined(separator: "\n")
        }
            .joined(separator: "\n")
    }
}

public extension [String] {
    mutating func next() -> String {
        nextOrNil() ?? errorT("args is empty")
    }

    mutating func nextOrNil() -> String? {
        let result = first
        self = Array(dropFirst())
        return result
    }
}

private extension ArgParserProtocol {
    func transformRaw(_ raw: T, _ arg: String, _ args: inout [String], _ errors: inout [String]) -> T {
        raw.copy(keyPath, parse(arg, &args).getOrNil(appendErrorTo: &errors))
    }
}

public protocol ArgParserProtocol<T> {
    associatedtype K
    associatedtype T where T : Copyable
    var keyPath: WritableKeyPath<T, K?> { get }
    var parse: (/*arg*/ String, /*nextArgs*/ inout [String]) -> Parsed<K> { get }
}

public struct ArgParser<T: Copyable, K>: ArgParserProtocol {
    public let keyPath: WritableKeyPath<T, K?>
    public let parse: (String, inout [String]) -> Parsed<K>

    public init(_ keyPath: WritableKeyPath<T, K?>, _ parse: @escaping (String, inout [String]) -> Parsed<K>) {
        self.keyPath = keyPath
        self.parse = parse
    }

    public init(_ keyPath: WritableKeyPath<T, K?>, _ parse: @escaping () -> Parsed<K>) {
        self.init(keyPath, { arg, nextArgs in parse() })
    }

    public init(_ keyPath: WritableKeyPath<T, K?>, _ parse: @escaping (inout [String]) -> Parsed<K>) {
        self.init(keyPath, { arg, nextArgs in parse(&nextArgs) })
    }

    public init(_ keyPath: WritableKeyPath<T, K?>, _ parse: @escaping (String) -> Parsed<K>) {
        self.init(keyPath, { arg, nextArgs in parse(arg) })
    }
}

public func trueBoolFlag<T: Copyable>(_ keyPath: WritableKeyPath<T, Bool?>) -> ArgParser<T, Bool> {
    ArgParser(keyPath) { .success(true) }
}

// todo reuse in config
public func parseEnum<T: RawRepresentable>(_ raw: String, _ _: T.Type) -> Parsed<T> where T.RawValue == String, T: CaseIterable {
    T(rawValue: raw).orFailure { "Can't parse '\(raw)'.\nPossible values: \(T.unionLiteral)" }
}

public func parseCardinalDirection(_ direction: String) -> Parsed<CardinalDirection> {
    parseEnum(direction, CardinalDirection.self)
}
