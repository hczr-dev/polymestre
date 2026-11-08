import Foundation

/// La calculatrice « comme sur papier » du mode étude, au-dessus de
/// `MathEngine` : ce qu'on tape est compris sans syntaxe à apprendre.
///
/// - `x^2 - 2` (une inconnue libre) → une fonction, tracée (`f`, `g`…) ;
/// - `x^2 = 2`, `z^5 = 1`, `cos(x) = x` → résolu : toutes les racines d'un
///   polynôme (complexes comprises, méthode de Durand–Kerner), sinon les
///   racines réelles trouvées par changement de signe ;
/// - `(1+2i)/(3-i)`, `e^(i pi)` → un nombre complexe, forme algébrique et polaire ;
/// - `A = [[1,2],[3,4]]`, `det(A)`, `inv(A)`, `rref(A)`, `A*B`, `solve(A, b)`
///   → l'algèbre linéaire de MATH-111, résultats en fractions quand ils le sont.
///
/// Pur, testé (`validate.sh`).
enum MathWorkbench {

    enum Output: Equatable {
        case value(String)
        case plotted(String)
        case solutions(variable: String, [String])
        case matrix([[String]])
        case complex(String, polar: String)
        case defined(String)
    }

    struct Session {
        var engine = MathEngine.Environment()
        var matrices: [String: Matrix] = [:]
    }

    static func run(_ line: String, in session: inout Session) throws -> Output {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw MathEngine.Failure.syntax(String(localized: "ligne vide")) }
        if MatrixParser.concerns(text, known: Set(session.matrices.keys)) {
            return try MatrixParser.run(text, in: &session)
        }
        let parts = text.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, !isDefinition(parts[0]) {
            return try solve(lhs: parts[0], rhs: parts[1], in: session.engine)
        }
        if parts.count == 1 {
            let node = try MathEngine.parseExpression(text)
            let free = freeNames(node, in: session.engine)
            if free == ["i"] || (free.isEmpty && mentions(node, "i") && session.engine.variables["i"] == nil) {
                let value = try ComplexMath.evaluate(node, in: session.engine)
                return .complex(value.algebraic, polar: value.polar)
            }
            if free.count == 1, let variable = free.first {
                let name = nextFunctionName(session.engine)
                session.engine.functions[name] = ([variable], node)
                return .plotted("\(name)(\(variable)) = \(text)")
            }
        }
        if let value = try session.engine.run(text) {
            return .value(format(value))
        }
        return .defined(text)
    }

    /// `a = …`, `f(x) = …` : une définition, pas une équation.
    static func isDefinition(_ lhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespaces)
        // `cos(x) = x` est une équation : `cos` ne se redéfinit pas.
        let name = String(left.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        if MathEngine.isReserved(name) { return false }
        if left.range(of: #"^[A-Za-zα-ωπ][A-Za-z0-9_]*$"#, options: .regularExpression) != nil { return true }
        return left.range(of: #"^[A-Za-z][A-Za-z0-9_]*\(\s*[A-Za-z][A-Za-z0-9_]*(\s*,\s*[A-Za-z][A-Za-z0-9_]*)*\s*\)$"#,
                          options: .regularExpression) != nil
    }

    // MARK: Inconnues

    static func freeNames(_ node: MathEngine.Node, in environment: MathEngine.Environment) -> Set<String> {
        switch node {
        case .number: return []
        case .variable(let name):
            return environment.variables[name] == nil && MathEngine.constants[name] == nil ? [name] : []
        case .negate(let inner), .factorial(let inner): return freeNames(inner, in: environment)
        case .binary(_, let a, let b): return freeNames(a, in: environment).union(freeNames(b, in: environment))
        case .call(let name, let arguments):
            // `int(f, 0, 1)` : `f` nomme une fonction, pas une inconnue.
            let skipFirst = ["int", "root"].contains(name)
            return arguments.enumerated().reduce(into: Set<String>()) { result, item in
                if skipFirst, item.offset == 0 { return }
                result.formUnion(freeNames(item.element, in: environment))
            }
        case .derivative(_, _, let inner): return freeNames(inner, in: environment)
        }
    }

    static func mentions(_ node: MathEngine.Node, _ name: String) -> Bool {
        switch node {
        case .number: return false
        case .variable(let n): return n == name
        case .negate(let inner), .factorial(let inner), .derivative(_, _, let inner): return mentions(inner, name)
        case .binary(_, let a, let b): return mentions(a, name) || mentions(b, name)
        case .call(_, let arguments): return arguments.contains { mentions($0, name) }
        }
    }

    static func nextFunctionName(_ environment: MathEngine.Environment) -> String {
        for name in ["f", "g", "h", "p", "q", "r", "u", "v", "w"] where environment.functions[name] == nil { return name }
        var index = 1
        while environment.functions["f\(index)"] != nil { index += 1 }
        return "f\(index)"
    }

    // MARK: Équations

    static func solve(lhs: String, rhs: String, in environment: MathEngine.Environment) throws -> Output {
        let left = try MathEngine.parseExpression(lhs), right = try MathEngine.parseExpression(rhs)
        let difference = MathEngine.Node.binary("-", left, right)
        var free = freeNames(difference, in: environment)
        let complex = free.contains("i") && free.count > 1
        if complex { free.remove("i") }
        guard free.count == 1, let variable = free.first else {
            throw MathEngine.Failure.domain(free.isEmpty ? String(localized: "Aucune inconnue à trouver.") : String(localized: "Une seule inconnue, s'il te plaît."))
        }
        if let polynomial = try? Polynomial.from(difference, variable: variable, in: environment), polynomial.degree >= 1 {
            let roots = polynomial.roots().sorted { ($0.re, $0.im) < ($1.re, $1.im) }
            return .solutions(variable: variable, roots.map(\.readable))
        }
        // Pas un polynôme : les racines réelles, par changement de signe.
        var local = environment
        local.functions["__solve"] = ([variable], difference)
        let roots = MathEngine.roots("__solve", from: -100, to: 100, in: local)
        guard !roots.isEmpty else { throw MathEngine.Failure.domain(String(localized: "Pas de solution réelle trouvée entre −100 et 100.")) }
        return .solutions(variable: variable, roots.map(format))
    }

    // MARK: Affichage

    /// `0.333…` → `1/3`, `2.5` → `5/2`, sinon le nombre arrondi.
    static func format(_ value: Double) -> String {
        if let fraction = fraction(value) { return fraction }
        return MathEngine.format(value)
    }

    static func fraction(_ value: Double) -> String? {
        guard value.isFinite, value != value.rounded() || abs(value) < 1e12 else { return nil }
        if abs(value - value.rounded()) < 1e-10 { return MathEngine.format(value.rounded()) }
        for denominator in 2...100 {
            let numerator = value * Double(denominator)
            if abs(numerator - numerator.rounded()) < 1e-9 * Double(denominator) {
                return "\(Int(numerator.rounded()))/\(denominator)"
            }
        }
        return nil
    }
}

// MARK: - Nombres complexes

struct Complex: Equatable {
    var re: Double
    var im: Double

    static let i = Complex(re: 0, im: 1)

    static func + (a: Complex, b: Complex) -> Complex { Complex(re: a.re + b.re, im: a.im + b.im) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(re: a.re - b.re, im: a.im - b.im) }
    static func * (a: Complex, b: Complex) -> Complex { Complex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re) }
    static func / (a: Complex, b: Complex) -> Complex {
        let d = b.re * b.re + b.im * b.im
        return Complex(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d)
    }
    static prefix func - (a: Complex) -> Complex { Complex(re: -a.re, im: -a.im) }

    var modulus: Double { (re * re + im * im).squareRoot() }
    var argument: Double { atan2(im, re) }

    static func exp(_ z: Complex) -> Complex { Complex(re: Foundation.exp(z.re) * cos(z.im), im: Foundation.exp(z.re) * sin(z.im)) }
    static func log(_ z: Complex) -> Complex { Complex(re: Foundation.log(z.modulus), im: z.argument) }

    static func pow(_ z: Complex, _ w: Complex) -> Complex {
        // Puissance entière : exacte (pas de détour par le logarithme).
        if w.im == 0, w.re == w.re.rounded(), abs(w.re) <= 64 {
            var result = Complex(re: 1, im: 0)
            for _ in 0..<Int(abs(w.re)) { result = result * z }
            return w.re < 0 ? Complex(re: 1, im: 0) / result : result
        }
        if z.re == 0, z.im == 0 { return Complex(re: 0, im: 0) }
        return exp(w * log(z))
    }

    /// `3 - 2i`, `1.5i`, `-1` (les restes d'arrondi effacés).
    var algebraic: String {
        func clean(_ x: Double) -> Double { abs(x) < 1e-10 ? 0 : x }
        let a = clean(re), b = clean(im)
        if b == 0 { return MathWorkbench.format(a) }
        let imaginary = abs(b) == 1 ? "i" : MathWorkbench.format(abs(b)) + "i"
        if a == 0 { return (b < 0 ? "-" : "") + imaginary }
        return MathWorkbench.format(a) + (b < 0 ? " - " : " + ") + imaginary
    }

    /// La forme la plus lisible : algébrique si elle est exacte (`1 + 2i`),
    /// polaire si l'angle est une fraction de π (`e^(i·2π/5)`), sinon algébrique.
    var readable: String {
        let exact = MathWorkbench.fraction(re) != nil && MathWorkbench.fraction(im) != nil
        if exact || abs(im) < 1e-10 { return algebraic }
        let ratio = argument / .pi
        guard MathWorkbench.fraction(ratio) != nil else { return algebraic }
        let r = MathWorkbench.fraction(modulus)
        return r == "1" ? String(polar.drop { $0 != "e" }) : polar
    }

    /// `2·e^(iπ/3)` : le module et l'argument (en fraction de π quand c'en est une).
    var polar: String {
        let r = MathWorkbench.format(modulus)
        let ratio = argument / .pi
        let angle: String
        if abs(argument) < 1e-12 { angle = "0" }
        else if let fraction = MathWorkbench.fraction(ratio) {
            angle = fraction == "1" ? "π" : (fraction == "-1" ? "-π" : (fraction.contains("/") ? fraction.replacingOccurrences(of: "/", with: "π/") : fraction + "π"))
        } else { angle = MathEngine.format(argument) }
        return "\(r)·e^(i·\(angle))"
    }
}

enum ComplexMath {
    static func evaluate(_ node: MathEngine.Node, in environment: MathEngine.Environment) throws -> Complex {
        func eval(_ node: MathEngine.Node) throws -> Complex { try evaluate(node, in: environment) }
        switch node {
        case .number(let value): return Complex(re: value, im: 0)
        case .variable(let name):
            if name == "i", environment.variables["i"] == nil { return .i }
            if let value = environment.variables[name] ?? MathEngine.constants[name] { return Complex(re: value, im: 0) }
            throw MathEngine.Failure.unknownName(name)
        case .negate(let inner): return -(try eval(inner))
        case .binary(let op, let a, let b):
            let x = try eval(a), y = try eval(b)
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            case "/":
                guard y.modulus > 0 else { throw MathEngine.Failure.domain(String(localized: "division par zéro")) }
                return x / y
            case "^": return Complex.pow(x, y)
            default: throw MathEngine.Failure.syntax(String(localized: "« \(op) »"))
            }
        case .call(let name, let arguments):
            guard arguments.count == 1 else { throw MathEngine.Failure.arity(name) }
            let z = try eval(arguments[0])
            switch name {
            case "re": return Complex(re: z.re, im: 0)
            case "im": return Complex(re: z.im, im: 0)
            case "conj": return Complex(re: z.re, im: -z.im)
            case "abs": return Complex(re: z.modulus, im: 0)
            case "arg": return Complex(re: z.argument, im: 0)
            case "exp": return Complex.exp(z)
            case "ln", "log": return Complex.log(z)
            case "sqrt": return Complex.pow(z, Complex(re: 0.5, im: 0))
            case "sin": return (Complex.exp(.i * z) - Complex.exp(-(.i * z))) / Complex(re: 0, im: 2)
            case "cos": return (Complex.exp(.i * z) + Complex.exp(-(.i * z))) / Complex(re: 2, im: 0)
            default:
                guard z.im == 0 else { throw MathEngine.Failure.domain(String(localized: "\(name) d'un complexe : pas pris en charge")) }
                return Complex(re: try MathEngine.evaluate(.call(name, [.number(z.re)]), in: environment), im: 0)
            }
        case .factorial, .derivative:
            return Complex(re: try MathEngine.evaluate(node, in: environment), im: 0)
        }
    }
}

// MARK: - Polynômes

/// Un polynôme à coefficients complexes (`coefficients[k]` devant `x^k`).
struct Polynomial: Equatable {
    var coefficients: [Complex]

    var degree: Int {
        var d = coefficients.count - 1
        while d > 0, coefficients[d].modulus < 1e-14 { d -= 1 }
        return d
    }

    static func + (a: Polynomial, b: Polynomial) -> Polynomial {
        let n = max(a.coefficients.count, b.coefficients.count)
        let zero = Complex(re: 0, im: 0)
        return Polynomial(coefficients: (0..<n).map { (a.coefficients.indices.contains($0) ? a.coefficients[$0] : zero)
            + (b.coefficients.indices.contains($0) ? b.coefficients[$0] : zero) })
    }
    static prefix func - (a: Polynomial) -> Polynomial { Polynomial(coefficients: a.coefficients.map { -$0 }) }
    static func * (a: Polynomial, b: Polynomial) -> Polynomial {
        var result = [Complex](repeating: Complex(re: 0, im: 0), count: a.coefficients.count + b.coefficients.count - 1)
        for (i, x) in a.coefficients.enumerated() { for (j, y) in b.coefficients.enumerated() { result[i + j] = result[i + j] + x * y } }
        return Polynomial(coefficients: result)
    }

    struct NotPolynomial: Error {}

    /// L'expression comme polynôme en `variable` ; échoue sinon (`sin(x)`, `1/x`…).
    static func from(_ node: MathEngine.Node, variable: String, in environment: MathEngine.Environment) throws -> Polynomial {
        func constant(_ node: MathEngine.Node) throws -> Polynomial {
            Polynomial(coefficients: [try ComplexMath.evaluate(node, in: environment)])
        }
        switch node {
        case .variable(let name) where name == variable:
            return Polynomial(coefficients: [Complex(re: 0, im: 0), Complex(re: 1, im: 0)])
        case .number, .variable:
            return try constant(node)
        case .negate(let inner):
            return -(try from(inner, variable: variable, in: environment))
        case .binary(let op, let a, let b):
            switch op {
            case "+": return try from(a, variable: variable, in: environment) + from(b, variable: variable, in: environment)
            case "-": return try from(a, variable: variable, in: environment) + -(from(b, variable: variable, in: environment))
            case "*": return try from(a, variable: variable, in: environment) * from(b, variable: variable, in: environment)
            case "/":
                guard !MathWorkbench.mentions(b, variable) else { throw NotPolynomial() }
                let divisor = try ComplexMath.evaluate(b, in: environment)
                return Polynomial(coefficients: try from(a, variable: variable, in: environment).coefficients.map { $0 / divisor })
            case "^":
                guard !MathWorkbench.mentions(b, variable) else { throw NotPolynomial() }
                let exponent = try MathEngine.evaluate(b, in: environment)
                guard exponent >= 0, exponent == exponent.rounded(), exponent <= 40 else { throw NotPolynomial() }
                let base = try from(a, variable: variable, in: environment)
                var result = Polynomial(coefficients: [Complex(re: 1, im: 0)])
                for _ in 0..<Int(exponent) { result = result * base }
                return result
            default: throw NotPolynomial()
            }
        default:
            guard !MathWorkbench.mentions(node, variable) else { throw NotPolynomial() }
            return try constant(node)
        }
    }

    /// Toutes les racines (Durand–Kerner), polies, les quasi-réelles ramenées au réel.
    func roots() -> [Complex] {
        let n = degree
        guard n >= 1 else { return [] }
        let lead = coefficients[n]
        let monic = coefficients[0...n].map { $0 / lead }
        func value(_ z: Complex) -> Complex { monic.reversed().reduce(Complex(re: 0, im: 0)) { $0 * z + $1 } }
        var roots = (0..<n).map { k in Complex.pow(Complex(re: 0.4, im: 0.9), Complex(re: Double(k), im: 0)) }
        for _ in 0..<500 {
            var change = 0.0
            for i in 0..<n {
                var denominator = Complex(re: 1, im: 0)
                for j in 0..<n where j != i { denominator = denominator * (roots[i] - roots[j]) }
                guard denominator.modulus > 0 else { continue }
                let step = value(roots[i]) / denominator
                roots[i] = roots[i] - step
                change = max(change, step.modulus)
            }
            if change < 1e-14 { break }
        }
        return roots.map { z in
            Complex(re: abs(z.re) < 1e-9 ? 0 : z.re, im: abs(z.im) < 1e-9 ? 0 : z.im)
        }
    }
}

// MARK: - Matrices

struct Matrix: Equatable {
    var rows: [[Double]]
    var rowCount: Int { rows.count }
    var columnCount: Int { rows.first?.count ?? 0 }

    static func identity(_ n: Int) -> Matrix { Matrix(rows: (0..<n).map { i in (0..<n).map { $0 == i ? 1 : 0 } }) }

    var transposed: Matrix { Matrix(rows: (0..<columnCount).map { j in rows.map { $0[j] } }) }

    static func * (a: Matrix, b: Matrix) throws -> Matrix {
        guard a.columnCount == b.rowCount else { throw MathEngine.Failure.domain("Tailles incompatibles (\(a.rowCount)×\(a.columnCount) · \(b.rowCount)×\(b.columnCount)).") }
        return Matrix(rows: a.rows.map { row in (0..<b.columnCount).map { j in zip(row, b.rows.map { $0[j] }).reduce(0) { $0 + $1.0 * $1.1 } } })
    }

    static func + (a: Matrix, b: Matrix) throws -> Matrix {
        guard a.rowCount == b.rowCount, a.columnCount == b.columnCount else { throw MathEngine.Failure.domain(String(localized: "Tailles différentes.")) }
        return Matrix(rows: zip(a.rows, b.rows).map { zip($0, $1).map(+) })
    }

    func scaled(_ k: Double) -> Matrix { Matrix(rows: rows.map { $0.map { $0 * k } }) }

    /// Forme échelonnée réduite (pivot de Gauss partiel), et le nombre de pivots.
    func reduced() -> (matrix: Matrix, rank: Int, determinantSign: Double, pivotProduct: Double) {
        var m = rows
        var lead = 0, rank = 0, sign = 1.0, product = 1.0
        for r in 0..<rowCount {
            guard lead < columnCount else { break }
            var i = r
            while abs(m[i][lead]) < 1e-12 {
                i += 1
                if i == rowCount { i = r; lead += 1; if lead == columnCount { return (Matrix(rows: m), rank, sign, product) } }
            }
            if i != r { m.swapAt(i, r); sign = -sign }
            let pivot = m[r][lead]
            product *= pivot
            m[r] = m[r].map { $0 / pivot }
            for k in 0..<rowCount where k != r {
                let factor = m[k][lead]
                m[k] = zip(m[k], m[r]).map { $0 - factor * $1 }
            }
            rank += 1
            lead += 1
        }
        return (Matrix(rows: m.map { $0.map { abs($0) < 1e-12 ? 0 : $0 } }), rank, sign, product)
    }

    func determinant() throws -> Double {
        guard rowCount == columnCount else { throw MathEngine.Failure.domain(String(localized: "Le déterminant demande une matrice carrée.")) }
        let reduced = self.reduced()
        return reduced.rank < rowCount ? 0 : reduced.determinantSign * reduced.pivotProduct
    }

    func inverse() throws -> Matrix {
        guard rowCount == columnCount else { throw MathEngine.Failure.domain(String(localized: "Seule une matrice carrée s'inverse.")) }
        let augmented = Matrix(rows: zip(rows, Matrix.identity(rowCount).rows).map { $0 + $1 }).reduced()
        guard augmented.rank == rowCount, (0..<rowCount).allSatisfy({ abs(augmented.matrix.rows[$0][$0] - 1) < 1e-9 }) else {
            throw MathEngine.Failure.domain(String(localized: "Matrice non inversible (déterminant nul)."))
        }
        return Matrix(rows: augmented.matrix.rows.map { Array($0[rowCount...]) })
    }

    var formatted: [[String]] { rows.map { $0.map(MathWorkbench.format) } }
}

/// Le petit langage des matrices : littéraux `[[1,2],[3,4]]`, noms, `+ - *`,
/// un scalaire devant, `^` entier, `det inv rref transpose rank trace solve`.
enum MatrixParser {
    static let functions: Set<String> = ["det", "inv", "rref", "transpose", "rank", "trace", "tr", "solve"]

    static func concerns(_ text: String, known: Set<String>) -> Bool {
        if text.contains("[") { return true }
        // Les noms, même collés à un nombre (`2A` → `A`).
        let regex = try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")
        let words = Set((regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [])
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        return !words.isDisjoint(with: known) || (!words.isDisjoint(with: functions) && !words.isDisjoint(with: known))
    }

    enum Value { case scalar(Double), matrix(Matrix) }

    static func run(_ text: String, in session: inout MathWorkbench.Session) throws -> MathWorkbench.Output {
        var source = text
        var target: String?
        if let equal = text.firstIndex(of: "="), text[..<equal].trimmingCharacters(in: .whitespaces).range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil {
            target = text[..<equal].trimmingCharacters(in: .whitespaces)
            source = String(text[text.index(after: equal)...])
        }
        var parser = Parser(chars: Array(source), session: session)
        let value = try parser.expression()
        parser.skip()
        guard parser.index == parser.chars.count else { throw MathEngine.Failure.syntax(String(localized: "fin inattendue")) }
        switch value {
        case .matrix(let m):
            if let target { session.matrices[target] = m }
            return .matrix(m.formatted)
        case .scalar(let x):
            if let target { session.engine.variables[target] = x }
            return .value(MathWorkbench.format(x))
        }
    }

    struct Parser {
        let chars: [Character]
        let session: MathWorkbench.Session
        var index = 0

        init(chars: [Character], session: MathWorkbench.Session) { self.chars = chars; self.session = session }

        mutating func skip() { while index < chars.count, chars[index] == " " { index += 1 } }
        mutating func eat(_ c: Character) -> Bool { skip(); if index < chars.count, chars[index] == c { index += 1; return true }; return false }

        mutating func expression() throws -> Value {
            var value = try term()
            while true {
                if eat("+") { value = try combine(value, try term(), "+") }
                else if eat("-") { value = try combine(value, try term(), "-") }
                else { return value }
            }
        }

        mutating func term() throws -> Value {
            var value = try power()
            while true {
                skip()
                if eat("*") { value = try combine(value, try power(), "*") }
                else if index < chars.count, chars[index] == "[" || chars[index].isLetter || chars[index] == "(" {
                    value = try combine(value, try power(), "*")
                } else { return value }
            }
        }

        mutating func power() throws -> Value {
            let base = try unary()
            guard eat("^") else { return base }
            guard case .scalar(let n) = try unary(), n == n.rounded() else { throw MathEngine.Failure.syntax("puissance entière attendue") }
            switch base {
            case .scalar(let x): return .scalar(Foundation.pow(x, n))
            case .matrix(let m):
                var result = Matrix.identity(m.rowCount)
                let factor = n < 0 ? try m.inverse() : m
                for _ in 0..<Int(abs(n)) { result = try result * factor }
                return .matrix(result)
            }
        }

        mutating func unary() throws -> Value {
            if eat("-") { return try combine(.scalar(-1), try unary(), "*") }
            return try primary()
        }

        mutating func primary() throws -> Value {
            skip()
            guard index < chars.count else { throw MathEngine.Failure.syntax(String(localized: "expression incomplète")) }
            let c = chars[index]
            if c == "(" { index += 1; let v = try expression(); guard eat(")") else { throw MathEngine.Failure.syntax(String(localized: "« ) » manquante")) }; return v }
            if c == "[" { return .matrix(try literal()) }
            if c.isNumber || c == "." {
                var text = ""
                while index < chars.count, chars[index].isNumber || chars[index] == "." { text.append(chars[index]); index += 1 }
                guard let value = Double(text) else { throw MathEngine.Failure.syntax(text) }
                return .scalar(value)
            }
            if c.isLetter {
                var name = ""
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { name.append(chars[index]); index += 1 }
                if MatrixParser.functions.contains(name), eat("(") {
                    var arguments = [try expression()]
                    while eat(",") { arguments.append(try expression()) }
                    guard eat(")") else { throw MathEngine.Failure.syntax(String(localized: "« ) » manquante")) }
                    return try apply(name, arguments)
                }
                if let m = session.matrices[name] { return .matrix(m) }
                if let x = session.engine.variables[name] ?? MathEngine.constants[name] { return .scalar(x) }
                throw MathEngine.Failure.unknownName(name)
            }
            throw MathEngine.Failure.syntax(String(localized: "« \(c) » inattendu"))
        }

        mutating func literal() throws -> Matrix {
            guard eat("[") else { throw MathEngine.Failure.syntax(String(localized: "« [ » attendu")) }
            var rows: [[Double]] = []
            if eat("[") {
                index -= 1
                repeat { rows.append(try row()) } while eat(",")
            } else {
                rows = [try numbers(until: "]")]
                guard eat("]") else { throw MathEngine.Failure.syntax(String(localized: "« ] » manquant")) }
                // `[1,2,3]` : un vecteur colonne.
                return Matrix(rows: rows[0].map { [$0] })
            }
            guard eat("]") else { throw MathEngine.Failure.syntax(String(localized: "« ] » manquant")) }
            guard let width = rows.first?.count, rows.allSatisfy({ $0.count == width }) else {
                throw MathEngine.Failure.domain(String(localized: "Les lignes n'ont pas toutes la même longueur."))
            }
            return Matrix(rows: rows)
        }

        mutating func row() throws -> [Double] {
            guard eat("[") else { throw MathEngine.Failure.syntax(String(localized: "« [ » attendu")) }
            let values = try numbers(until: "]")
            guard eat("]") else { throw MathEngine.Failure.syntax(String(localized: "« ] » manquant")) }
            return values
        }

        mutating func numbers(until end: Character) throws -> [Double] {
            var values: [Double] = []
            repeat {
                skip()
                var text = ""
                var depth = 0
                while index < chars.count, (chars[index] != "," && chars[index] != end) || depth > 0 {
                    if chars[index] == "(" { depth += 1 }
                    if chars[index] == ")" { depth -= 1 }
                    text.append(chars[index]); index += 1
                }
                var environment = session.engine
                values.append(try MathEngine.evaluate(MathEngine.parseExpression(text), in: environment))
                environment.variables = [:]
            } while eat(",")
            return values
        }

        func apply(_ name: String, _ arguments: [Value]) throws -> Value {
            func matrix(_ value: Value) throws -> Matrix {
                if case .matrix(let m) = value { return m }
                throw MathEngine.Failure.domain(String(localized: "\(name) attend une matrice"))
            }
            switch name {
            case "det": return .scalar(try matrix(arguments[0]).determinant())
            case "inv": return .matrix(try matrix(arguments[0]).inverse())
            case "rref": return .matrix(try matrix(arguments[0]).reduced().matrix)
            case "transpose": return .matrix(try matrix(arguments[0]).transposed)
            case "rank": return .scalar(Double(try matrix(arguments[0]).reduced().rank))
            case "trace", "tr":
                let m = try matrix(arguments[0])
                return .scalar((0..<min(m.rowCount, m.columnCount)).reduce(0) { $0 + m.rows[$1][$1] })
            case "solve":
                guard arguments.count == 2 else { throw MathEngine.Failure.arity(name) }
                return .matrix(try matrix(arguments[0]).inverse() * matrix(arguments[1]))
            default: throw MathEngine.Failure.unknownName(name)
            }
        }

        func combine(_ a: Value, _ b: Value, _ op: Character) throws -> Value {
            switch (a, b, op) {
            case (.scalar(let x), .scalar(let y), "+"): return .scalar(x + y)
            case (.scalar(let x), .scalar(let y), "-"): return .scalar(x - y)
            case (.scalar(let x), .scalar(let y), _): return .scalar(x * y)
            case (.matrix(let m), .matrix(let n), "+"): return .matrix(try m + n)
            case (.matrix(let m), .matrix(let n), "-"): return .matrix(try m + n.scaled(-1))
            case (.matrix(let m), .matrix(let n), _): return .matrix(try m * n)
            case (.scalar(let x), .matrix(let m), "*"), (.matrix(let m), .scalar(let x), "*"): return .matrix(m.scaled(x))
            default: throw MathEngine.Failure.domain(String(localized: "On n'ajoute pas un nombre à une matrice."))
            }
        }
    }
}
