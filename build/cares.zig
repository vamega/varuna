const std = @import("std");

pub const Library = struct {
    lib: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,

    pub fn link(self: *const @This(), mod: *std.Build.Module) void {
        mod.linkLibrary(self.lib);
        mod.addIncludePath(self.include_path);
    }
};

/// All c-ares C sources (relative to vendor/c-ares/src/lib/).
/// Matches the CSOURCES list in vendor/c-ares/src/lib/Makefile.inc,
/// minus platform-specific files that are excluded for Linux below.
const sources = [_][]const u8{
    "ares_addrinfo2hostent.c",
    "ares_addrinfo_localhost.c",
    "ares_cancel.c",
    "ares_close_sockets.c",
    "ares_conn.c",
    "ares_cookie.c",
    "ares_data.c",
    "ares_destroy.c",
    "ares_free_hostent.c",
    "ares_free_string.c",
    "ares_freeaddrinfo.c",
    "ares_getaddrinfo.c",
    "ares_getenv.c",
    "ares_gethostbyaddr.c",
    "ares_gethostbyname.c",
    "ares_getnameinfo.c",
    "ares_hosts_file.c",
    "ares_init.c",
    "ares_library_init.c",
    "ares_metrics.c",
    "ares_options.c",
    "ares_parse_into_addrinfo.c",
    "ares_process.c",
    "ares_qcache.c",
    "ares_query.c",
    "ares_search.c",
    "ares_send.c",
    "ares_set_socket_functions.c",
    "ares_socket.c",
    "ares_sortaddrinfo.c",
    "ares_strerror.c",
    "ares_sysconfig.c",
    "ares_sysconfig_files.c",
    "ares_timeout.c",
    "ares_update_servers.c",
    "ares_version.c",
    "inet_net_pton.c",
    "inet_ntop.c",
    // dsa/
    "dsa/ares_array.c",
    "dsa/ares_htable.c",
    "dsa/ares_htable_asvp.c",
    "dsa/ares_htable_dict.c",
    "dsa/ares_htable_strvp.c",
    "dsa/ares_htable_szvp.c",
    "dsa/ares_htable_vpstr.c",
    "dsa/ares_htable_vpvp.c",
    "dsa/ares_llist.c",
    "dsa/ares_slist.c",
    // event/
    "event/ares_event_configchg.c",
    "event/ares_event_epoll.c",
    "event/ares_event_kqueue.c",
    "event/ares_event_poll.c",
    "event/ares_event_select.c",
    "event/ares_event_thread.c",
    "event/ares_event_wake_pipe.c",
    // legacy/
    "legacy/ares_create_query.c",
    "legacy/ares_expand_name.c",
    "legacy/ares_expand_string.c",
    "legacy/ares_fds.c",
    "legacy/ares_getsock.c",
    "legacy/ares_parse_a_reply.c",
    "legacy/ares_parse_aaaa_reply.c",
    "legacy/ares_parse_caa_reply.c",
    "legacy/ares_parse_mx_reply.c",
    "legacy/ares_parse_naptr_reply.c",
    "legacy/ares_parse_ns_reply.c",
    "legacy/ares_parse_ptr_reply.c",
    "legacy/ares_parse_soa_reply.c",
    "legacy/ares_parse_srv_reply.c",
    "legacy/ares_parse_txt_reply.c",
    "legacy/ares_parse_uri_reply.c",
    // record/
    "record/ares_dns_mapping.c",
    "record/ares_dns_multistring.c",
    "record/ares_dns_name.c",
    "record/ares_dns_parse.c",
    "record/ares_dns_record.c",
    "record/ares_dns_write.c",
    // str/
    "str/ares_buf.c",
    "str/ares_str.c",
    "str/ares_strsplit.c",
    // util/
    "util/ares_iface_ips.c",
    "util/ares_math.c",
    "util/ares_rand.c",
    "util/ares_threads.c",
    "util/ares_timeval.c",
    "util/ares_uri.c",
};

/// Excluded from the Linux build:
///   ares_android.c      — Android-only (__ANDROID__)
///   ares_sysconfig_mac.c — macOS-only
///   ares_sysconfig_win.c — Windows-only
///   windows_port.c      — Windows-only
///   event/ares_event_win32.c — Windows IOCP

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Library {
    const lib = b.addLibrary(.{
        .name = "cares",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });

    lib.link_function_sections = true;
    lib.link_data_sections = true;
    lib.link_gc_sections = true;

    const root = b.path("vendor/c-ares/src/lib");
    const public_include = b.path("vendor/c-ares/include");
    const private_include = b.path("vendor/c-ares/src/lib/include");
    const generated_include = b.path("build/cares-generated");

    // Private includes: the source directory itself (for ares_private.h etc.),
    // src/lib/include/ (for ares_mem.h, ares_buf.h, etc.),
    // and the public include directory (for ares.h, ares_dns.h, etc.)
    lib.root_module.addIncludePath(root);
    lib.root_module.addIncludePath(private_include);
    lib.root_module.addIncludePath(public_include);

    // Our pre-built config headers (ares_config.h, ares_build.h) for Linux.
    // These replace the CMake-generated headers.
    lib.root_module.addIncludePath(generated_include);

    // Compile definitions matching CMake: HAVE_CONFIG_H makes ares_setup.h
    // include our ares_config.h, and CARES_BUILDING_LIBRARY enables internal symbols.
    lib.root_module.addCMacro("HAVE_CONFIG_H", "1");
    lib.root_module.addCMacro("CARES_BUILDING_LIBRARY", "1");
    lib.root_module.addCMacro("CARES_STATICLIB", "1");
    lib.root_module.addCMacro("_GNU_SOURCE", "1");

    // Link pthread (c-ares uses threads for the event thread)
    lib.root_module.linkSystemLibrary("pthread", .{});

    lib.root_module.addCSourceFiles(.{
        .files = &sources,
        .root = root,
        .flags = &.{
            // gnu11 exposes POSIX/GNU extensions (clock_gettime, pipe2,
            // getservbyname_r, memmem, etc.) that c-ares requires.
            "-std=gnu11",
            "-fvisibility=hidden",
        },
    });

    return .{
        .lib = lib,
        .include_path = public_include,
    };
}
