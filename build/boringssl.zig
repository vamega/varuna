const std = @import("std");

const CXX_NO_RUNTIME_FLAGS = &.{
    "-fno-exceptions",
    "-fno-rtti",
};

pub const Libraries = struct {
    bcm: *std.Build.Step.Compile,
    crypto: *std.Build.Step.Compile,
    ssl: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,

    pub fn linkCrypto(self: *const @This(), compile: *std.Build.Step.Compile) void {
        compile.root_module.linkLibrary(self.bcm);
        compile.root_module.linkLibrary(self.crypto);
        compile.root_module.addIncludePath(self.include_path);
    }

    pub fn linkSsl(self: *const @This(), compile: *std.Build.Step.Compile) void {
        compile.root_module.linkLibrary(self.ssl);
        self.linkCrypto(compile);
    }
};

const Sources = struct {
    const WithAsm = struct {
        srcs: std.json.Value,
        @"asm": std.json.Value,
    };

    const WithoutAsm = struct {
        srcs: std.json.Value,
    };

    bcm: WithAsm,
    crypto: WithAsm,
    ssl: WithoutAsm,
};

pub fn create(
    b: *std.Build,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Libraries {
    const manifest_path = std.fs.path.join(
        b.allocator,
        &.{ root.getPath(b), "gen", "sources.json" },
    ) catch @panic("OOM");
    defer b.allocator.free(manifest_path);

    const data = readFileAlloc(b, manifest_path);
    defer b.allocator.free(data);

    const parsed = std.json.parseFromSlice(
        Sources,
        b.allocator,
        data,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("failed to parse boringssl sources.json");
    defer parsed.deinit();

    const include_path = b.path("vendor/boringssl/include");
    const has_asm = supportsAsm(target);

    const bcm = b.addLibrary(.{
        .name = "boringssl-bcm",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    configureLibraryDefaults(bcm, include_path, has_asm);
    addSources(b, bcm, root, parsed.value.bcm.srcs, CXX_NO_RUNTIME_FLAGS);
    addAsmSources(b, bcm, root, target, parsed.value.bcm.@"asm");

    const crypto = b.addLibrary(.{
        .name = "boringssl-crypto",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    configureLibraryDefaults(crypto, include_path, has_asm);
    crypto.root_module.linkLibrary(bcm);
    if (target.result.os.tag == .linux) {
        crypto.root_module.linkSystemLibrary("pthread", .{});
    }
    addSources(b, crypto, root, parsed.value.crypto.srcs, CXX_NO_RUNTIME_FLAGS);
    addAsmSources(b, crypto, root, target, parsed.value.crypto.@"asm");

    const ssl = b.addLibrary(.{
        .name = "boringssl-ssl",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
        .linkage = .static,
    });
    configureLibraryDefaults(ssl, include_path, has_asm);
    ssl.root_module.linkLibrary(crypto);
    addSources(b, ssl, root, parsed.value.ssl.srcs, CXX_NO_RUNTIME_FLAGS);

    return .{
        .bcm = bcm,
        .crypto = crypto,
        .ssl = ssl,
        .include_path = include_path,
    };
}

fn readFileAlloc(b: *std.Build, path: []const u8) []u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch @panic("failed to open file");
    defer file.close();

    return file.readToEndAlloc(b.allocator, std.math.maxInt(usize)) catch @panic("failed to read file");
}

fn configureLibraryDefaults(
    lib: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
    has_asm: bool,
) void {
    lib.link_function_sections = true;
    lib.link_data_sections = true;
    lib.link_gc_sections = true;
    lib.root_module.addIncludePath(include_path);
    lib.root_module.addCMacro("BORINGSSL_IMPLEMENTATION", "1");
    if (!has_asm) {
        lib.root_module.addCMacro("OPENSSL_NO_ASM", "1");
    }
}

fn addSources(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    root: std.Build.LazyPath,
    arr: std.json.Value,
    flags: []const []const u8,
) void {
    var sources = unpackJsonSources(arr, b.allocator);
    defer sources.deinit(b.allocator);

    lib.root_module.addCSourceFiles(.{
        .files = sources.items,
        .root = root,
        .flags = flags,
    });
}

fn addAsmSources(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    arr: std.json.Value,
) void {
    var asm_sources = std.ArrayList([]const u8).empty;
    defer asm_sources.deinit(b.allocator);

    for (arr.array.items) |it| {
        const source = it.string;
        if (isCompatibleAsmSource(target, source)) {
            asm_sources.append(b.allocator, source) catch @panic("OOM");
        }
    }

    if (asm_sources.items.len == 0) return;

    lib.root_module.addCSourceFiles(.{
        .files = asm_sources.items,
        .root = root,
        .language = .assembly_with_preprocessor,
    });
}

fn unpackJsonSources(arr: std.json.Value, alloc: std.mem.Allocator) std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    for (arr.array.items) |it| {
        result.append(alloc, it.string) catch @panic("OOM");
    }
    return result;
}

fn supportsAsm(target: std.Build.ResolvedTarget) bool {
    if (target.result.os.tag != .linux) return false;

    return switch (target.result.cpu.arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };
}

fn isCompatibleAsmSource(target: std.Build.ResolvedTarget, source: []const u8) bool {
    if (!supportsAsm(target)) return false;

    if (!std.mem.endsWith(u8, source, "-linux.S")) {
        return isCompatibleFiatAsm(target, source);
    }

    return switch (target.result.cpu.arch) {
        .x86_64 => std.mem.indexOf(u8, source, "x86_64") != null or std.mem.eql(u8, source, "gen/bcm/rsaz-avx2-linux.S"),
        .aarch64 => std.mem.indexOf(u8, source, "armv8") != null,
        else => false,
    };
}

fn isCompatibleFiatAsm(target: std.Build.ResolvedTarget, source: []const u8) bool {
    if (!std.mem.startsWith(u8, source, "third_party/fiat/asm/")) {
        return false;
    }

    return switch (target.result.cpu.arch) {
        .x86_64 => true,
        .aarch64 => false,
        else => false,
    };
}
