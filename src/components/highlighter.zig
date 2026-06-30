const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

pub const TokenKind = enum {
    keyword,
    builtin,
    string,
    comment,
    number,
};

pub const Token = struct {
    start: usize,
    end: usize,
    kind: TokenKind,
};

pub fn tokenize(allocator: Allocator, source: []const u8, lang: []const u8) Allocator.Error![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    const hash_cmt = usesHashComment(lang);
    const slash_cmt = usesSlashComment(lang);
    const block_cmt = usesBlockComment(lang);
    const dq = usesDqString(lang);
    const sq = usesSqString(lang);

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];

        // Hash comment: # … EOL
        if (hash_cmt and c == '#') {
            const s = i;
            while (i < source.len and source[i] != '\n') i += 1;
            try tokens.append(allocator, .{ .start = s, .end = i, .kind = .comment });
            continue;
        }

        // Line comment: // … EOL
        if (slash_cmt and c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            const s = i;
            while (i < source.len and source[i] != '\n') i += 1;
            try tokens.append(allocator, .{ .start = s, .end = i, .kind = .comment });
            continue;
        }

        // Block comment: /* … */
        if (block_cmt and c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            const s = i;
            i += 2;
            while (i < source.len) {
                if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            try tokens.append(allocator, .{ .start = s, .end = i, .kind = .comment });
            continue;
        }

        // Double-quoted string "…"
        if (dq and c == '"') {
            const s = i;
            i += 1;
            while (i < source.len) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                } else if (source[i] == '"') {
                    i += 1;
                    break;
                } else if (source[i] == '\n') {
                    break;
                } else {
                    i += 1;
                }
            }
            try tokens.append(allocator, .{ .start = s, .end = i, .kind = .string });
            continue;
        }

        // Single-quoted string '…'
        if (sq and c == '\'') {
            const s = i;
            i += 1;
            while (i < source.len) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                } else if (source[i] == '\'') {
                    i += 1;
                    break;
                } else if (source[i] == '\n') {
                    break;
                } else {
                    i += 1;
                }
            }
            try tokens.append(allocator, .{ .start = s, .end = i, .kind = .string });
            continue;
        }

        // Number
        if (std.ascii.isDigit(c)) {
            const s = i;
            if (c == '0' and i + 1 < source.len and (source[i + 1] == 'x' or source[i + 1] == 'X')) {
                i += 2;
                while (i < source.len and isHexDigit(source[i])) i += 1;
            } else {
                while (i < source.len and (std.ascii.isDigit(source[i]) or
                    source[i] == '.' or source[i] == '_' or
                    source[i] == 'e' or source[i] == 'E'))
                {
                    i += 1;
                }
            }
            try tokens.append(allocator, .{ .start = s, .end = i, .kind = .number });
            continue;
        }

        // Identifier / keyword
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const s = i;
            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) i += 1;
            const ident = source[s..i];
            if (getKeywordKind(ident, lang)) |kind| {
                try tokens.append(allocator, .{ .start = s, .end = i, .kind = kind });
            }
            continue;
        }

        i += 1;
    }

    return tokens.toOwnedSlice(allocator);
}

pub fn styleAtByte(tokens: []const Token, byte: usize, default: vaxis.Style) vaxis.Style {
    var lo: usize = 0;
    var hi: usize = tokens.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const tok = tokens[mid];
        if (byte < tok.start) {
            hi = mid;
        } else if (byte >= tok.end) {
            lo = mid + 1;
        } else {
            return styleFor(tok.kind);
        }
    }
    return default;
}

pub fn styleFor(kind: TokenKind) vaxis.Style {
    return switch (kind) {
        .keyword => .{ .fg = .{ .rgb = .{ 0xC6, 0x78, 0xDD } } },
        .builtin => .{ .fg = .{ .rgb = .{ 0x61, 0xAF, 0xEF } } },
        .string => .{ .fg = .{ .rgb = .{ 0x98, 0xC3, 0x79 } } },
        .comment => .{ .fg = .{ .rgb = .{ 0x5C, 0x63, 0x70 } }, .italic = true },
        .number => .{ .fg = .{ .rgb = .{ 0xD1, 0x9A, 0x66 } } },
    };
}

// ── language feature detection ────────────────────────────────────────────────

fn usesHashComment(lang: []const u8) bool {
    const list = [_][]const u8{ "bash", "sh", "zsh", "fish", "python", "python3", "py", "ruby", "rb", "perl", "pl", "yaml", "yml", "toml", "conf", "ini", "r", "dockerfile", "makefile" };
    for (list) |l| if (std.ascii.eqlIgnoreCase(lang, l)) return true;
    return false;
}

fn usesSlashComment(lang: []const u8) bool {
    const list = [_][]const u8{ "zig", "c", "cpp", "cc", "cxx", "h", "hpp", "java", "javascript", "js", "typescript", "ts", "jsx", "tsx", "rust", "rs", "go", "swift", "kotlin", "kt", "cs", "dart", "php", "scala" };
    for (list) |l| if (std.ascii.eqlIgnoreCase(lang, l)) return true;
    return false;
}

fn usesBlockComment(lang: []const u8) bool {
    const list = [_][]const u8{ "c", "cpp", "cc", "cxx", "h", "hpp", "java", "javascript", "js", "typescript", "ts", "jsx", "tsx", "rust", "rs", "go", "swift", "kotlin", "kt", "cs", "css", "dart", "php", "scala" };
    for (list) |l| if (std.ascii.eqlIgnoreCase(lang, l)) return true;
    return false;
}

fn usesDqString(lang: []const u8) bool {
    const no_dq = [_][]const u8{ "makefile" };
    for (no_dq) |l| if (std.ascii.eqlIgnoreCase(lang, l)) return false;
    return lang.len > 0;
}

fn usesSqString(lang: []const u8) bool {
    const list = [_][]const u8{ "bash", "sh", "zsh", "fish", "python", "python3", "py", "ruby", "rb", "javascript", "js", "typescript", "ts", "jsx", "tsx", "rust", "rs", "php", "zig" };
    for (list) |l| if (std.ascii.eqlIgnoreCase(lang, l)) return true;
    return false;
}

// ── keyword tables ────────────────────────────────────────────────────────────

fn getKeywordKind(ident: []const u8, lang: []const u8) ?TokenKind {
    if (std.ascii.eqlIgnoreCase(lang, "bash") or std.ascii.eqlIgnoreCase(lang, "sh") or std.ascii.eqlIgnoreCase(lang, "zsh") or std.ascii.eqlIgnoreCase(lang, "fish")) {
        const kws = [_][]const u8{ "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "local", "export", "readonly", "declare", "true", "false", "exit", "break", "continue", "shift", "set", "unset", "source", "trap", "wait", "exec", "eval", "read", "select", "time" };
        const bts = [_][]const u8{ "echo", "printf", "cd", "pwd", "ls", "cat", "grep", "sed", "awk", "find", "mkdir", "rmdir", "rm", "cp", "mv", "chmod", "chown", "ln", "test", "curl", "wget", "git", "docker", "npm", "yarn", "pip", "python", "python3", "node", "make", "cmake", "cargo", "go", "zig", "type", "which", "env", "export" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
        for (bts) |k| if (std.mem.eql(u8, ident, k)) return .builtin;
    } else if (std.ascii.eqlIgnoreCase(lang, "zig")) {
        const kws = [_][]const u8{ "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while" };
        const bts = [_][]const u8{ "bool", "comptime_float", "comptime_int", "f16", "f32", "f64", "f80", "f128", "i8", "i16", "i32", "i64", "i128", "isize", "noreturn", "null", "type", "undefined", "void", "u8", "u16", "u32", "u64", "u128", "usize", "true", "false", "anyerror", "anyopaque" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
        for (bts) |k| if (std.mem.eql(u8, ident, k)) return .builtin;
    } else if (std.ascii.eqlIgnoreCase(lang, "python") or std.ascii.eqlIgnoreCase(lang, "py") or std.ascii.eqlIgnoreCase(lang, "python3")) {
        const kws = [_][]const u8{ "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
    } else if (std.ascii.eqlIgnoreCase(lang, "javascript") or std.ascii.eqlIgnoreCase(lang, "js") or
        std.ascii.eqlIgnoreCase(lang, "typescript") or std.ascii.eqlIgnoreCase(lang, "ts") or
        std.ascii.eqlIgnoreCase(lang, "jsx") or std.ascii.eqlIgnoreCase(lang, "tsx"))
    {
        const kws = [_][]const u8{ "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "null", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield", "async", "await", "of", "from", "type", "interface", "implements", "abstract", "declare", "enum", "namespace", "as" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
    } else if (std.ascii.eqlIgnoreCase(lang, "rust") or std.ascii.eqlIgnoreCase(lang, "rs")) {
        const kws = [_][]const u8{ "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while" };
        const bts = [_][]const u8{ "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "str", "String", "Vec", "Option", "Result", "Some", "None", "Ok", "Err" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
        for (bts) |k| if (std.mem.eql(u8, ident, k)) return .builtin;
    } else if (std.ascii.eqlIgnoreCase(lang, "go")) {
        const kws = [_][]const u8{ "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var" };
        const bts = [_][]const u8{ "append", "cap", "close", "complex", "copy", "delete", "imag", "len", "make", "new", "panic", "print", "println", "real", "recover", "bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "nil", "true", "false", "iota" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
        for (bts) |k| if (std.mem.eql(u8, ident, k)) return .builtin;
    } else if (std.ascii.eqlIgnoreCase(lang, "json")) {
        const kws = [_][]const u8{ "true", "false", "null" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
    } else if (std.ascii.eqlIgnoreCase(lang, "c") or std.ascii.eqlIgnoreCase(lang, "cpp") or std.ascii.eqlIgnoreCase(lang, "cc") or std.ascii.eqlIgnoreCase(lang, "cxx") or std.ascii.eqlIgnoreCase(lang, "h") or std.ascii.eqlIgnoreCase(lang, "hpp")) {
        const kws = [_][]const u8{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "true", "false", "nullptr", "class", "template", "namespace", "using", "public", "private", "protected", "virtual", "override", "new", "delete", "this" };
        for (kws) |k| if (std.mem.eql(u8, ident, k)) return .keyword;
    }
    return null;
}

fn isHexDigit(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
