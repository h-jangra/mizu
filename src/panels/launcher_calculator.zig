const std = @import("std");
const c = @import("../c.zig").c;

pub const CalcError = error{
    InvalidCharacter,
    UnexpectedToken,
    DivisionByZero,
    EmptyExpression,
    MismatchedParentheses,
    DomainError,
    Overflow,
    ExpressionTooLong,
    RecursionLimitExceeded,
    TooManyTokens,
};

pub fn evaluate(input: []const u8) CalcError!f64 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyExpression;
    if (trimmed.len > Parser.MAX_INPUT_LEN) return error.ExpressionTooLong;

    var p = Parser{
        .source = trimmed,
        .pos = 0,
    };
    const res = try p.parseExpr();
    p.skipWhitespace();
    if (p.pos < p.source.len) {
        return error.UnexpectedToken;
    }
    return res;
}

const Parser = struct {
    source: []const u8,
    pos: usize,
    depth: usize = 0,
    tokens: usize = 0,

    pub const MAX_INPUT_LEN: usize = 256;
    pub const MAX_DEPTH: usize = 32;
    pub const MAX_TOKENS: usize = 128;

    fn checkToken(self: *Parser) CalcError!void {
        self.tokens += 1;
        if (self.tokens > MAX_TOKENS) {
            return error.TooManyTokens;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn parseExpr(self: *Parser) CalcError!f64 {
        if (self.depth >= MAX_DEPTH) {
            return error.RecursionLimitExceeded;
        }
        self.depth += 1;
        defer self.depth -= 1;
        return self.parseAddSub();
    }

    fn parseAddSub(self: *Parser) CalcError!f64 {
        var left = try self.parseMulDiv();
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;
            const ch = self.source[self.pos];
            if (ch == '+') {
                try self.checkToken();
                self.pos += 1;
                const right = try self.parseMulDiv();
                left += right;
            } else if (ch == '-') {
                try self.checkToken();
                self.pos += 1;
                const right = try self.parseMulDiv();
                left -= right;
            } else {
                break;
            }
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) CalcError!f64 {
        var left = try self.parsePower();
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;
            const ch = self.source[self.pos];
            if (ch == '*') {
                try self.checkToken();
                self.pos += 1;
                const right = try self.parsePower();
                left *= right;
            } else if (ch == '/') {
                try self.checkToken();
                self.pos += 1;
                const right = try self.parsePower();
                if (right == 0.0) return error.DivisionByZero;
                left /= right;
            } else if (ch == '%') {
                try self.checkToken();
                self.pos += 1;
                const right = try self.parsePower();
                if (right == 0.0) return error.DivisionByZero;
                left = @mod(left, right);
            } else {
                break;
            }
        }
        return left;
    }

    fn parsePower(self: *Parser) CalcError!f64 {
        const left = try self.parseUnary();
        self.skipWhitespace();
        if (self.pos < self.source.len and self.source[self.pos] == '^') {
            if (self.depth >= MAX_DEPTH) return error.RecursionLimitExceeded;
            self.depth += 1;
            defer self.depth -= 1;
            try self.checkToken();
            self.pos += 1;
            const right = try self.parsePower();
            return std.math.pow(f64, left, right);
        }
        return left;
    }

    fn parseUnary(self: *Parser) CalcError!f64 {
        self.skipWhitespace();
        if (self.pos >= self.source.len) return error.UnexpectedToken;
        if (self.source[self.pos] == '+') {
            if (self.depth >= MAX_DEPTH) return error.RecursionLimitExceeded;
            self.depth += 1;
            defer self.depth -= 1;
            try self.checkToken();
            self.pos += 1;
            return self.parseUnary();
        } else if (self.source[self.pos] == '-') {
            if (self.depth >= MAX_DEPTH) return error.RecursionLimitExceeded;
            self.depth += 1;
            defer self.depth -= 1;
            try self.checkToken();
            self.pos += 1;
            const val = try self.parseUnary();
            return -val;
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) CalcError!f64 {
        self.skipWhitespace();
        if (self.pos >= self.source.len) return error.UnexpectedToken;

        const ch = self.source[self.pos];
        if (ch == '(') {
            try self.checkToken();
            self.pos += 1;
            const val = try self.parseExpr();
            self.skipWhitespace();
            if (self.pos >= self.source.len or self.source[self.pos] != ')') {
                return error.MismatchedParentheses;
            }
            try self.checkToken();
            self.pos += 1;
            return val;
        }

        if (std.ascii.isDigit(ch) or ch == '.') {
            try self.checkToken();
            return self.parseNumber();
        }

        if (std.ascii.isAlphabetic(ch)) {
            try self.checkToken();
            return self.parseIdentOrCall();
        }

        return error.InvalidCharacter;
    }

    fn parseNumber(self: *Parser) CalcError!f64 {
        const start = self.pos;
        var has_dot = false;
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isDigit(ch)) {
                self.pos += 1;
            } else if (ch == '.' and !has_dot) {
                has_dot = true;
                self.pos += 1;
            } else {
                break;
            }
        }
        const num_str = self.source[start..self.pos];
        return std.fmt.parseFloat(f64, num_str) catch error.UnexpectedToken;
    }

    fn parseIdentOrCall(self: *Parser) CalcError!f64 {
        const start = self.pos;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }
        const ident = self.source[start..self.pos];

        if (std.ascii.eqlIgnoreCase(ident, "pi")) return std.math.pi;
        if (std.ascii.eqlIgnoreCase(ident, "e")) return std.math.e;

        // Function call: must be followed by '('
        self.skipWhitespace();
        if (self.pos >= self.source.len or self.source[self.pos] != '(') {
            return error.UnexpectedToken;
        }
        try self.checkToken();
        self.pos += 1;
        const arg = try self.parseExpr();
        self.skipWhitespace();
        if (self.pos >= self.source.len or self.source[self.pos] != ')') {
            return error.MismatchedParentheses;
        }
        try self.checkToken();
        self.pos += 1;

        if (std.ascii.eqlIgnoreCase(ident, "sqrt")) {
            if (arg < 0) return error.DomainError;
            return @sqrt(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "abs")) {
            return @abs(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "sin")) {
            return @sin(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "cos")) {
            return @cos(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "tan")) {
            return @tan(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "ln") or std.ascii.eqlIgnoreCase(ident, "log")) {
            if (arg <= 0) return error.DomainError;
            return @log(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "log10")) {
            if (arg <= 0) return error.DomainError;
            return @log10(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "round")) {
            return @round(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "floor")) {
            return @floor(arg);
        } else if (std.ascii.eqlIgnoreCase(ident, "ceil")) {
            return @ceil(arg);
        }

        return error.UnexpectedToken;
    }
};

pub fn formatResult(buf: []u8, val: f64) []const u8 {
    if (std.math.isNan(val)) return "NaN";
    if (std.math.isPositiveInf(val)) return "Infinity";
    if (std.math.isNegativeInf(val)) return "-Infinity";

    if (val == @trunc(val) and @abs(val) < 1e14) {
        const int_val = @as(i64, @intFromFloat(val));
        return std.fmt.bufPrint(buf, "{d}", .{int_val}) catch "0";
    }

    const s = std.fmt.bufPrint(buf, "{d:.6}", .{val}) catch return "0";
    var trimmed = s;
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '0') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

test "evaluate expressions" {
    try std.testing.expectEqual(@as(f64, 25.0), try evaluate("125 / 5"));
    try std.testing.expectEqual(@as(f64, 14.0), try evaluate("2 + 3 * 4"));
    try std.testing.expectEqual(@as(f64, 20.0), try evaluate("(2 + 3) * 4"));
    try std.testing.expectEqual(@as(f64, 1024.0), try evaluate("2^10"));
    try std.testing.expectEqual(@as(f64, 12.0), try evaluate("sqrt(144)"));
    try std.testing.expectEqual(@as(f64, 5.0), try evaluate("-5 + 10"));
    try std.testing.expectError(error.DivisionByZero, evaluate("10 / 0"));

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("25", formatResult(&buf, 25.0));
    try std.testing.expectEqualStrings("2.5", formatResult(&buf, 2.5));
}

test "calc security limits" {
    // 1. Expression too long (> 256 bytes)
    var long_buf: [300]u8 = undefined;
    @memset(&long_buf, '1');
    try std.testing.expectError(error.ExpressionTooLong, evaluate(&long_buf));

    // 2. Recursion limit exceeded (> 32 nested parentheses)
    // Construct 35 nested parentheses: (((...1...)))
    var deep_buf: [100]u8 = undefined;
    var idx: usize = 0;
    for (0..35) |_| {
        deep_buf[idx] = '(';
        idx += 1;
    }
    deep_buf[idx] = '1';
    idx += 1;
    for (0..35) |_| {
        deep_buf[idx] = ')';
        idx += 1;
    }
    try std.testing.expectError(error.RecursionLimitExceeded, evaluate(deep_buf[0..idx]));

    // 3. Token count limit exceeded (> 128 tokens)
    // 1+1+1... with 70 pairs of "+1" = 141 tokens in 141 bytes (< 256 bytes limit)
    var token_buf: [200]u8 = undefined;
    var t_idx: usize = 0;
    token_buf[t_idx] = '1';
    t_idx += 1;
    for (0..70) |_| {
        token_buf[t_idx] = '+';
        token_buf[t_idx + 1] = '1';
        t_idx += 2;
    }
    try std.testing.expectError(error.TooManyTokens, evaluate(token_buf[0..t_idx]));
}
