/* c-ares build header for Linux, generated for the varuna Zig build.
 *
 * This replaces the CMake-generated ares_build.h.  It matches what CMake
 * would produce on a modern Linux system with ssize_t and socklen_t.
 * Hardcoded for glibc >= 2.36; see ares_config.h for rationale and
 * the validation recipe.
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef __CARES_BUILD_H
#define __CARES_BUILD_H

#define CARES_TYPEOF_ARES_SOCKLEN_T socklen_t
#define CARES_TYPEOF_ARES_SSIZE_T   ssize_t

#define CARES_HAVE_SYS_TYPES_H      1
#define CARES_HAVE_SYS_SOCKET_H     1
#define CARES_HAVE_SYS_SELECT_H     1
#define CARES_HAVE_ARPA_NAMESER_H   1
#define CARES_HAVE_ARPA_NAMESER_COMPAT_H 1

#ifdef CARES_HAVE_SYS_TYPES_H
#  include <sys/types.h>
#endif

#ifdef CARES_HAVE_SYS_SOCKET_H
#  include <sys/socket.h>
#endif

#ifdef CARES_HAVE_SYS_SELECT_H
#  include <sys/select.h>
#endif

#endif /* __CARES_BUILD_H */
