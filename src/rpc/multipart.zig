const std = @import("std");

/// A single part from a multipart/form-data body.
/// All slices point into the original body buffer (zero-copy).
pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: []const u8,
};

pub const ParseError = error{
    MissingBoundary,
    MalformedHeader,
    NoParts,
    OutOfMemory,
};

/// Extract the boundary string from a Content-Type header value.
/// Input: "multipart/form-data; boundary=----WebKitFormBoundaryXYZ"
/// Output: "----WebKitFormBoundaryXYZ"
pub fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const prefix = "boundary=";
    const idx = std.mem.indexOf(u8, content_type, prefix) orelse return null;
    var boundary = content_type[idx + prefix.len ..];

    // Strip optional quotes
    if (boundary.len >= 2 and boundary[0] == '"') {
        boundary = boundary[1..];
        if (std.mem.indexOfScalar(u8, boundary, '"')) |end| {
            boundary = boundary[0..end];
        }
    }

    // Trim trailing whitespace/semicolons
    while (boundary.len > 0 and (boundary[boundary.len - 1] == ' ' or
        boundary[boundary.len - 1] == ';' or
        boundary[boundary.len - 1] == '\r' or
        boundary[boundary.len - 1] == '\n'))
    {
        boundary = boundary[0 .. boundary.len - 1];
    }

    return if (boundary.len > 0) boundary else null;
}

/// Parse a multipart/form-data body into parts.
/// Returns allocated slice of Part structs; each Part's slices point into the
/// original body (zero-copy). Caller owns the returned slice and must free it
/// with the same allocator.
pub fn parse(allocator: std.mem.Allocator, content_type: []const u8, body: []const u8) ParseError![]const Part {
    const boundary = extractBoundary(content_type) orelse return ParseError.MissingBoundary;

    const delim_prefix = "--";

    var parts = std.ArrayList(Part).empty;
    errdefer parts.deinit(allocator);

    // Find first boundary
    var pos: usize = 0;
    pos = findBoundary(body, pos, delim_prefix, boundary) orelse return ParseError.NoParts;

    while (pos < body.len) {
        // Check for closing boundary (--boundary--)
        if (pos + 2 <= body.len and std.mem.eql(u8, body[pos .. pos + 2], "--")) {
            break;
        }

        // Skip the \r\n after boundary
        if (pos < body.len and body[pos] == '\r') pos += 1;
        if (pos < body.len and body[pos] == '\n') pos += 1;

        // Parse headers until empty line
        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var part_content_type: ?[]const u8 = null;

        while (pos < body.len) {
            const line_end = std.mem.indexOfPos(u8, body, pos, "\r\n") orelse break;
            const line = body[pos..line_end];
            pos = line_end + 2;

            if (line.len == 0) break; // Empty line = end of headers

            // Parse Content-Disposition
            if (asciiStartsWithIgnoreCase(line, "content-disposition:")) {
                const value = std.mem.trimLeft(u8, line["content-disposition:".len..], " ");
                name = extractHeaderParam(value, "name");
                filename = extractHeaderParam(value, "filename");
            }

            // Parse Content-Type
            if (asciiStartsWithIgnoreCase(line, "content-type:")) {
                part_content_type = std.mem.trimLeft(u8, line["content-type:".len..], " ");
            }
        }

        if (name == null) {
            // Skip malformed part, try to find next boundary
            pos = findBoundary(body, pos, delim_prefix, boundary) orelse break;
            continue;
        }

        // Data runs from current pos to the next boundary
        // The boundary is preceded by \r\n
        const data_start = pos;
        const next_boundary = findBoundaryInData(body, pos, delim_prefix, boundary) orelse body.len;

        // Strip trailing \r\n before boundary
        var data_end = next_boundary;
        if (data_end >= 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') {
            data_end -= 2;
        }

        parts.append(allocator, .{
            .name = name.?,
            .filename = filename,
            .content_type = part_content_type,
            .data = body[data_start..data_end],
        }) catch return ParseError.OutOfMemory;

        // Move past the boundary
        pos = next_boundary + delim_prefix.len + boundary.len;
    }

    if (parts.items.len == 0) return ParseError.NoParts;

    return parts.toOwnedSlice(allocator) catch ParseError.OutOfMemory;
}

/// Free parts returned by parse().
pub fn freeParts(allocator: std.mem.Allocator, parts: []const Part) void {
    allocator.free(parts);
}

/// Find "--boundary" starting at `from`, return position after it.
fn findBoundary(body: []const u8, from: usize, delim_prefix: []const u8, boundary: []const u8) ?usize {
    var pos = from;
    while (pos + delim_prefix.len + boundary.len <= body.len) {
        if (std.mem.eql(u8, body[pos .. pos + delim_prefix.len], delim_prefix) and
            std.mem.eql(u8, body[pos + delim_prefix.len .. pos + delim_prefix.len + boundary.len], boundary))
        {
            return pos + delim_prefix.len + boundary.len;
        }
        pos += 1;
    }
    return null;
}

/// Find the byte position where "--boundary" starts (not past it).
fn findBoundaryInData(body: []const u8, from: usize, delim_prefix: []const u8, boundary: []const u8) ?usize {
    var pos = from;
    while (pos + delim_prefix.len + boundary.len <= body.len) {
        if (std.mem.eql(u8, body[pos .. pos + delim_prefix.len], delim_prefix) and
            std.mem.eql(u8, body[pos + delim_prefix.len .. pos + delim_prefix.len + boundary.len], boundary))
        {
            return pos;
        }
        pos += 1;
    }
    return null;
}

/// Extract a named parameter from a header value.
/// e.g. extractHeaderParam("form-data; name=\"torrents\"; filename=\"f.torrent\"", "name") -> "torrents"
fn extractHeaderParam(header: []const u8, param: []const u8) ?[]const u8 {
    // Look for param="value" or param=value
    var pos: usize = 0;
    while (pos < header.len) {
        // Find the parameter name
        const idx = std.mem.indexOfPos(u8, header, pos, param) orelse return null;
        const after_name = idx + param.len;

        // Must be preceded by start, space or semicolon
        if (idx > 0 and header[idx - 1] != ' ' and header[idx - 1] != ';') {
            pos = after_name;
            continue;
        }

        // Must be followed by =
        if (after_name >= header.len or header[after_name] != '=') {
            pos = after_name;
            continue;
        }

        var val_start = after_name + 1;
        if (val_start >= header.len) return null;

        if (header[val_start] == '"') {
            // Quoted value
            val_start += 1;
            const val_end = std.mem.indexOfScalarPos(u8, header, val_start, '"') orelse return null;
            return header[val_start..val_end];
        } else {
            // Unquoted value (until semicolon, space, or end)
            var val_end = val_start;
            while (val_end < header.len and header[val_end] != ';' and header[val_end] != ' ') {
                val_end += 1;
            }
            return header[val_start..val_end];
        }
    }
    return null;
}

/// Case-insensitive prefix check for ASCII strings.
fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (haystack[0..prefix.len], prefix) |h, p| {
        if (std.ascii.toLower(h) != std.ascii.toLower(p)) return false;
    }
    return true;
}

/// Check if a Content-Type header indicates multipart/form-data.
pub fn isMultipart(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    return asciiStartsWithIgnoreCase(ct, "multipart/form-data");
}

/// Find a part by name in a parsed parts slice.
pub fn findPart(parts: []const Part, name: []const u8) ?Part {
    for (parts) |part| {
        if (std.mem.eql(u8, part.name, name)) return part;
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────

test "extract boundary from content-type" {
    try std.testing.expectEqualStrings(
        "----WebKitFormBoundaryABC123",
        extractBoundary("multipart/form-data; boundary=----WebKitFormBoundaryABC123").?,
    );
    try std.testing.expectEqualStrings(
        "myboundary",
        extractBoundary("multipart/form-data; boundary=\"myboundary\"").?,
    );
    try std.testing.expect(extractBoundary("application/json") == null);
    try std.testing.expect(extractBoundary("multipart/form-data") == null);
}

test "parse single torrent upload" {
    const boundary = "----WebKitFormBoundaryXYZ";
    const body = "------WebKitFormBoundaryXYZ\r\n" ++
        "Content-Disposition: form-data; name=\"torrents\"; filename=\"test.torrent\"\r\n" ++
        "Content-Type: application/x-bittorrent\r\n" ++
        "\r\n" ++
        "TORRENTDATA" ++
        "\r\n------WebKitFormBoundaryXYZ--\r\n";

    const parts = try parse(std.testing.allocator, "multipart/form-data; boundary=" ++ boundary, body);
    defer freeParts(std.testing.allocator, parts);
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqualStrings("torrents", parts[0].name);
    try std.testing.expectEqualStrings("test.torrent", parts[0].filename.?);
    try std.testing.expectEqualStrings("application/x-bittorrent", parts[0].content_type.?);
    try std.testing.expectEqualStrings("TORRENTDATA", parts[0].data);
}

test "parse Flood-style multipart with params" {
    const boundary = "----FormBoundary123";
    const body = "------FormBoundary123\r\n" ++
        "Content-Disposition: form-data; name=\"torrents\"; filename=\"file.torrent\"\r\n" ++
        "Content-Type: application/x-bittorrent\r\n" ++
        "\r\n" ++
        "BINARYDATA" ++
        "\r\n------FormBoundary123\r\n" ++
        "Content-Disposition: form-data; name=\"savepath\"\r\n" ++
        "\r\n" ++
        "/downloads" ++
        "\r\n------FormBoundary123\r\n" ++
        "Content-Disposition: form-data; name=\"sequentialDownload\"\r\n" ++
        "\r\n" ++
        "true" ++
        "\r\n------FormBoundary123--\r\n";

    const ct = "multipart/form-data; boundary=" ++ boundary;
    const parts = try parse(std.testing.allocator, ct, body);
    defer freeParts(std.testing.allocator, parts);

    try std.testing.expectEqual(@as(usize, 3), parts.len);

    const torrent_part = findPart(parts, "torrents").?;
    try std.testing.expectEqualStrings("BINARYDATA", torrent_part.data);
    try std.testing.expectEqualStrings("file.torrent", torrent_part.filename.?);

    const savepath_part = findPart(parts, "savepath").?;
    try std.testing.expectEqualStrings("/downloads", savepath_part.data);
    try std.testing.expect(savepath_part.filename == null);

    const seq_part = findPart(parts, "sequentialDownload").?;
    try std.testing.expectEqualStrings("true", seq_part.data);
}

test "parse rejects missing boundary" {
    const result = parse(std.testing.allocator, "application/json", "nobody");
    try std.testing.expectError(ParseError.MissingBoundary, result);
}

test "parse rejects body with no parts" {
    const result = parse(std.testing.allocator, "multipart/form-data; boundary=xxx", "no boundary here");
    try std.testing.expectError(ParseError.NoParts, result);
}

test "isMultipart detects content type" {
    try std.testing.expect(isMultipart("multipart/form-data; boundary=abc"));
    try std.testing.expect(isMultipart("Multipart/Form-Data; boundary=abc"));
    try std.testing.expect(!isMultipart("application/json"));
    try std.testing.expect(!isMultipart(null));
}

test "extractHeaderParam handles various formats" {
    try std.testing.expectEqualStrings(
        "torrents",
        extractHeaderParam("form-data; name=\"torrents\"; filename=\"f.torrent\"", "name").?,
    );
    try std.testing.expectEqualStrings(
        "f.torrent",
        extractHeaderParam("form-data; name=\"torrents\"; filename=\"f.torrent\"", "filename").?,
    );
    try std.testing.expect(extractHeaderParam("form-data; name=\"test\"", "filename") == null);
}

// ── Fuzz and edge case tests ─────────────────────────────

test "fuzz multipart parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            // Split input: first half as content_type, second half as body.
            // This exercises both extractBoundary and parse with random data.
            const split = input.len / 2;
            const content_type = input[0..split];
            const body = input[split..];

            // extractBoundary must not panic
            _ = extractBoundary(content_type);

            // parse must not panic
            const parts = parse(std.testing.allocator, content_type, body) catch return;
            freeParts(std.testing.allocator, parts);
        }
    }.run, .{
        .corpus = &.{
            // Valid multipart
            "multipart/form-data; boundary=XXX" ++
                "--XXX\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\ndata\r\n--XXX--\r\n",
            // Missing boundary parameter
            "application/jsonsome body here",
            // Empty input
            "",
            // Just boundary keyword
            "boundary=",
            // Boundary but no parts in body
            "multipart/form-data; boundary=abc" ++ "no boundary markers",
            // Quoted boundary
            "multipart/form-data; boundary=\"qb\"" ++ "--qb\r\n\r\n\r\n--qb--",
        },
    });
}

test "multipart parser edge cases: empty and single bytes" {
    // Empty content_type and body
    try std.testing.expectError(ParseError.MissingBoundary, parse(std.testing.allocator, "", ""));

    // Single byte inputs for content_type
    var ct: [1]u8 = undefined;
    var byte: u16 = 0;
    while (byte <= 0xFF) : (byte += 1) {
        ct[0] = @intCast(byte);
        _ = extractBoundary(&ct);
        const result = parse(std.testing.allocator, &ct, "");
        if (result) |parts| {
            freeParts(std.testing.allocator, parts);
        } else |_| {}
    }
}

test "multipart parser handles truncated valid input" {
    const valid = "multipart/form-data; boundary=XXX" ++
        "--XXX\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\ndata\r\n--XXX--\r\n";

    // Feed progressively longer prefixes -- none should panic
    for (0..valid.len) |i| {
        const truncated = valid[0..i];
        const split = truncated.len / 2;
        const result = parse(std.testing.allocator, truncated[0..split], truncated[split..]);
        if (result) |parts| {
            freeParts(std.testing.allocator, parts);
        } else |_| {}
    }
}
