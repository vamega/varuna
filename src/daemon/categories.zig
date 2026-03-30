const std = @import("std");

/// A torrent category with an optional save path override.
pub const Category = struct {
    name: []const u8,
    save_path: []const u8,
};

/// In-memory store for torrent categories.
/// Thread-safety: callers must hold the SessionManager mutex.
pub const CategoryStore = struct {
    allocator: std.mem.Allocator,
    categories: std.StringHashMap(Category),

    pub fn init(allocator: std.mem.Allocator) CategoryStore {
        return .{
            .allocator = allocator,
            .categories = std.StringHashMap(Category).init(allocator),
        };
    }

    pub fn deinit(self: *CategoryStore) void {
        var iter = self.categories.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.save_path);
        }
        self.categories.deinit();
    }

    /// Create a new category. Returns error if it already exists.
    pub fn create(self: *CategoryStore, name: []const u8, save_path: []const u8) !void {
        if (name.len == 0) return error.InvalidCategoryName;
        if (self.categories.contains(name)) return error.CategoryAlreadyExists;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_path = try self.allocator.dupe(u8, save_path);
        errdefer self.allocator.free(owned_path);

        try self.categories.put(owned_name, .{
            .name = owned_name,
            .save_path = owned_path,
        });
    }

    /// Edit an existing category's save path. Returns error if not found.
    pub fn edit(self: *CategoryStore, name: []const u8, save_path: []const u8) !void {
        const entry = self.categories.getPtr(name) orelse return error.CategoryNotFound;
        const owned_path = try self.allocator.dupe(u8, save_path);
        self.allocator.free(entry.save_path);
        entry.save_path = owned_path;
    }

    /// Remove a category by name. No-op if it doesn't exist (matching qBittorrent behavior).
    pub fn remove(self: *CategoryStore, name: []const u8) void {
        if (self.categories.fetchRemove(name)) |kv| {
            self.allocator.free(kv.value.name);
            self.allocator.free(kv.value.save_path);
        }
    }

    /// Get a category by name.
    pub fn get(self: *const CategoryStore, name: []const u8) ?Category {
        return self.categories.get(name);
    }

    /// Serialize all categories as JSON: {"name":{"name":"...","savePath":"..."},...}
    pub fn serializeJson(self: *const CategoryStore, allocator: std.mem.Allocator) ![]u8 {
        var json = std.ArrayList(u8).empty;
        errdefer json.deinit(allocator);

        try json.append(allocator, '{');
        var first = true;
        var iter = self.categories.iterator();
        while (iter.next()) |entry| {
            if (!first) try json.append(allocator, ',');
            first = false;
            try json.print(allocator, "\"{s}\":{{\"name\":\"{s}\",\"savePath\":\"{s}\"}}", .{
                entry.value_ptr.name,
                entry.value_ptr.name,
                entry.value_ptr.save_path,
            });
        }
        try json.append(allocator, '}');

        return json.toOwnedSlice(allocator);
    }
};

/// In-memory store for torrent tags.
/// Thread-safety: callers must hold the SessionManager mutex.
pub const TagStore = struct {
    allocator: std.mem.Allocator,
    tags: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) TagStore {
        return .{
            .allocator = allocator,
            .tags = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *TagStore) void {
        var iter = self.tags.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tags.deinit();
    }

    /// Create a tag. No-op if it already exists.
    pub fn create(self: *TagStore, name: []const u8) !void {
        if (name.len == 0) return;
        if (self.tags.contains(name)) return;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.tags.put(owned, {});
    }

    /// Delete a tag. No-op if it doesn't exist.
    pub fn delete(self: *TagStore, name: []const u8) void {
        if (self.tags.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Check if a tag exists.
    pub fn contains(self: *const TagStore, name: []const u8) bool {
        return self.tags.contains(name);
    }

    /// Serialize all tags as JSON array: ["tag1","tag2",...]
    pub fn serializeJson(self: *const TagStore, allocator: std.mem.Allocator) ![]u8 {
        var json = std.ArrayList(u8).empty;
        errdefer json.deinit(allocator);

        try json.append(allocator, '[');
        var first = true;
        var iter = self.tags.iterator();
        while (iter.next()) |entry| {
            if (!first) try json.append(allocator, ',');
            first = false;
            try json.print(allocator, "\"{s}\"", .{entry.key_ptr.*});
        }
        try json.append(allocator, ']');

        return json.toOwnedSlice(allocator);
    }
};

// ── Tests ─────────────────────────────────────────────────

test "category store create and list" {
    const allocator = std.testing.allocator;
    var store = CategoryStore.init(allocator);
    defer store.deinit();

    try store.create("movies", "/data/movies");
    try store.create("tv", "/data/tv");

    try std.testing.expectError(error.CategoryAlreadyExists, store.create("movies", "/other"));
    try std.testing.expectError(error.InvalidCategoryName, store.create("", ""));

    const cat = store.get("movies").?;
    try std.testing.expectEqualStrings("movies", cat.name);
    try std.testing.expectEqualStrings("/data/movies", cat.save_path);

    const json = try store.serializeJson(allocator);
    defer allocator.free(json);
    // Should contain both categories
    try std.testing.expect(std.mem.indexOf(u8, json, "\"movies\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tv\"") != null);
}

test "category store edit and remove" {
    const allocator = std.testing.allocator;
    var store = CategoryStore.init(allocator);
    defer store.deinit();

    try store.create("movies", "/data/movies");
    try store.edit("movies", "/new/path");

    const cat = store.get("movies").?;
    try std.testing.expectEqualStrings("/new/path", cat.save_path);

    try std.testing.expectError(error.CategoryNotFound, store.edit("nonexistent", "/path"));

    store.remove("movies");
    try std.testing.expect(store.get("movies") == null);

    // Removing nonexistent category is a no-op
    store.remove("nonexistent");
}

test "tag store create and delete" {
    const allocator = std.testing.allocator;
    var store = TagStore.init(allocator);
    defer store.deinit();

    try store.create("linux");
    try store.create("archived");
    try store.create("linux"); // duplicate is no-op

    try std.testing.expect(store.contains("linux"));
    try std.testing.expect(store.contains("archived"));

    const json = try store.serializeJson(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"linux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"archived\"") != null);

    store.delete("linux");
    try std.testing.expect(!store.contains("linux"));

    // Deleting nonexistent tag is a no-op
    store.delete("nonexistent");
}

test "tag store empty serialization" {
    const allocator = std.testing.allocator;
    var store = TagStore.init(allocator);
    defer store.deinit();

    const json = try store.serializeJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("[]", json);
}

test "category store empty serialization" {
    const allocator = std.testing.allocator;
    var store = CategoryStore.init(allocator);
    defer store.deinit();

    const json = try store.serializeJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{}", json);
}
