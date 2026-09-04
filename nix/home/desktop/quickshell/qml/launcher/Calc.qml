// A small arithmetic evaluator for the launcher's `=` provider.
//
// beamenu used the evalexpr crate for this. The obvious QML replacement is to
// hand the string to Function() or eval, which is the same as letting anything
// typed into a launcher run as code in the shell process. This is a
// recursive-descent parser instead: it understands arithmetic and nothing
// else, so the worst a hostile string can do is fail to parse.
//
// Grammar, lowest precedence first:
//   expression := term (('+' | '-') term)*
//   term       := power (('*' | '/' | '%') power)*
//   power      := unary ('^' power)?        right associative
//   unary      := ('-' | '+')? primary
//   primary    := number | '(' expression ')'
import QtQuick

QtObject {
    id: root

    // Returns a number, or undefined when the input is not a complete and
    // valid expression. Undefined rather than NaN so callers can tell "not an
    // expression" from "an expression that evaluated to NaN".
    function evaluate(source: string): var {
        const tokens = root.tokenize(source);
        if (!tokens)
            return undefined;

        const state = {
            tokens: tokens,
            position: 0
        };

        const value = root.parseExpression(state);
        if (value === undefined)
            return undefined;

        // Trailing junk means the whole string was not an expression, so "1 2"
        // must fail rather than quietly answering 1.
        if (state.position !== tokens.length)
            return undefined;

        return Number.isFinite(value) ? value : undefined;
    }

    function tokenize(source: string): var {
        const tokens = [];
        let index = 0;

        while (index < source.length) {
            const character = source[index];

            if (character === " " || character === "\t" || character === "_") {
                index += 1;
                continue;
            }

            if (character >= "0" && character <= "9" || character === ".") {
                let end = index;
                while (end < source.length && (source[end] >= "0" && source[end] <= "9" || source[end] === ".")) {
                    end += 1;
                }

                const numeric = Number(source.slice(index, end));
                if (!Number.isFinite(numeric))
                    return null;

                tokens.push({
                    kind: "number",
                    value: numeric
                });
                index = end;
                continue;
            }

            if ("+-*/%^()".includes(character)) {
                tokens.push({
                    kind: character
                });
                index += 1;
                continue;
            }

            return null;
        }

        return tokens.length > 0 ? tokens : null;
    }

    function peek(state: var): var {
        return state.position < state.tokens.length ? state.tokens[state.position] : null;
    }

    function parseExpression(state: var): var {
        let left = root.parseTerm(state);
        if (left === undefined)
            return undefined;

        for (;;) {
            const token = root.peek(state);
            if (!token || token.kind !== "+" && token.kind !== "-")
                return left;

            state.position += 1;
            const right = root.parseTerm(state);
            if (right === undefined)
                return undefined;

            left = token.kind === "+" ? left + right : left - right;
        }
    }

    function parseTerm(state: var): var {
        let left = root.parsePower(state);
        if (left === undefined)
            return undefined;

        for (;;) {
            const token = root.peek(state);
            if (!token || token.kind !== "*" && token.kind !== "/" && token.kind !== "%")
                return left;

            state.position += 1;
            const right = root.parsePower(state);
            if (right === undefined)
                return undefined;

            if (token.kind === "*") {
                left = left * right;
            } else if (token.kind === "/") {
                if (right === 0)
                    return undefined;

                left = left / right;
            } else {
                if (right === 0)
                    return undefined;

                left = left % right;
            }
        }
    }

    function parsePower(state: var): var {
        const base = root.parseUnary(state);
        if (base === undefined)
            return undefined;

        const token = root.peek(state);
        if (!token || token.kind !== "^")
            return base;

        state.position += 1;

        // Recurse into power, not unary, because exponentiation associates
        // right: 2^3^2 is 2^9, not 8^2.
        const exponent = root.parsePower(state);
        if (exponent === undefined)
            return undefined;

        return Math.pow(base, exponent);
    }

    function parseUnary(state: var): var {
        const token = root.peek(state);
        if (!token)
            return undefined;

        if (token.kind === "-") {
            state.position += 1;
            const negated = root.parseUnary(state);
            return negated === undefined ? undefined : -negated;
        }

        if (token.kind === "+") {
            state.position += 1;
            return root.parseUnary(state);
        }

        return root.parsePrimary(state);
    }

    function parsePrimary(state: var): var {
        const token = root.peek(state);
        if (!token)
            return undefined;

        if (token.kind === "number") {
            state.position += 1;
            return token.value;
        }

        if (token.kind === "(") {
            state.position += 1;

            const inner = root.parseExpression(state);
            if (inner === undefined)
                return undefined;

            const closing = root.peek(state);
            if (!closing || closing.kind !== ")")
                return undefined;

            state.position += 1;
            return inner;
        }

        return undefined;
    }
}
