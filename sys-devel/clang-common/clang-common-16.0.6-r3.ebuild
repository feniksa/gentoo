# Copyright 1999-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit bash-completion-r1 llvm.org

DESCRIPTION="Common files shared between multiple slots of clang"
HOMEPAGE="https://llvm.org/"

LICENSE="Apache-2.0-with-LLVM-exceptions UoI-NCSA"
SLOT="0"
KEYWORDS="amd64 arm arm64 ~loong ppc ppc64 ~riscv sparc x86 ~amd64-linux ~arm64-macos ~ppc-macos ~x64-macos"
IUSE="
	default-compiler-rt default-libcxx default-lld
	bootstrap-prefix hardened llvm-libunwind
"

PDEPEND="
	sys-devel/clang:*
	default-compiler-rt? (
		sys-devel/clang-runtime[compiler-rt]
		llvm-libunwind? ( sys-libs/llvm-libunwind[static-libs] )
		!llvm-libunwind? ( sys-libs/libunwind[static-libs] )
	)
	!default-compiler-rt? ( sys-devel/gcc )
	default-libcxx? ( >=sys-libs/libcxx-${PV}[static-libs] )
	!default-libcxx? ( sys-devel/gcc )
	default-lld? ( sys-devel/lld )
	!default-lld? ( sys-devel/binutils )
"
IDEPEND="
	!default-compiler-rt? ( sys-devel/gcc-config )
	!default-libcxx? ( sys-devel/gcc-config )
"

LLVM_COMPONENTS=( clang/utils )
llvm.org_set_globals

pkg_pretend() {
	[[ ${CLANG_IGNORE_DEFAULT_RUNTIMES} ]] && return

	local flag missing_flags=()
	for flag in default-{compiler-rt,libcxx,lld}; do
		if ! use "${flag}" && has_version "sys-devel/clang[${flag}]"; then
			missing_flags+=( "${flag}" )
		fi
	done

	if [[ ${missing_flags[@]} ]]; then
		eerror "It seems that you have the following flags set on sys-devel/clang:"
		eerror
		eerror "  ${missing_flags[*]}"
		eerror
		eerror "The default runtimes are now set via flags on sys-devel/clang-common."
		eerror "The build is being aborted to prevent breakage.  Please either set"
		eerror "the respective flags on this ebuild, e.g.:"
		eerror
		eerror "  sys-devel/clang-common ${missing_flags[*]}"
		eerror
		eerror "or build with CLANG_IGNORE_DEFAULT_RUNTIMES=1."
		die "Mismatched defaults detected between sys-devel/clang and sys-devel/clang-common"
	fi
}

src_install() {
	newbashcomp bash-autocomplete.sh clang

	insinto /etc/clang
	newins - gentoo-runtimes.cfg <<-EOF
		# This file is initially generated by sys-devel/clang-runtime.
		# It is used to control the default runtimes using by clang.

		--rtlib=$(usex default-compiler-rt compiler-rt libgcc)
		--unwindlib=$(usex default-compiler-rt libunwind libgcc)
		--stdlib=$(usex default-libcxx libc++ libstdc++)
		-fuse-ld=$(usex default-lld lld bfd)
	EOF

	newins - gentoo-gcc-install.cfg <<-EOF
		# This file is maintained by gcc-config.
		# It is used to specify the selected GCC installation.
	EOF

	newins - gentoo-common.cfg <<-EOF
		# This file contains flags common to clang, clang++ and clang-cpp.
		@gentoo-runtimes.cfg
		@gentoo-gcc-install.cfg
		@gentoo-hardened.cfg
		# bug #870001
		-include "${EPREFIX}/usr/include/gentoo/maybe-stddefs.h"
	EOF

	# Baseline hardening (bug #851111)
	newins - gentoo-hardened.cfg <<-EOF
		# Some of these options are added unconditionally, regardless of
		# USE=hardened, for parity with sys-devel/gcc.
		-Xarch_host -fstack-clash-protection
		-Xarch_host -fstack-protector-strong
		-fPIE
		-include "${EPREFIX}/usr/include/gentoo/fortify.h"
	EOF

	dodir /usr/include/gentoo

	cat >> "${ED}/usr/include/gentoo/maybe-stddefs.h" <<-EOF || die
	/* __has_include is an extension, but it's fine, because this is only
	for Clang anyway. */
	#if defined __has_include && __has_include (<stdc-predef.h>) && !defined(__GLIBC__)
	# include <stdc-predef.h>
	#endif
	EOF

	local fortify_level=$(usex hardened 3 2)
	# We have to do this because glibc's headers warn if F_S is set
	# without optimization and that would at the very least be very noisy
	# during builds and at worst trigger many -Werror builds.
	cat >> "${ED}/usr/include/gentoo/fortify.h" <<- EOF || die
	#ifdef __clang__
	# pragma clang system_header
	#endif
	#ifndef _FORTIFY_SOURCE
	# if defined(__has_feature)
	#  define __GENTOO_HAS_FEATURE(x) __has_feature(x)
	# else
	#  define __GENTOO_HAS_FEATURE(x) 0
	# endif
	#
	# if defined(__OPTIMIZE__) && __OPTIMIZE__ > 0
	#  if !defined(__SANITIZE_ADDRESS__) && !__GENTOO_HAS_FEATURE(address_sanitizer) && !__GENTOO_HAS_FEATURE(memory_sanitizer)
	#   define _FORTIFY_SOURCE ${fortify_level}
	#  endif
	# endif
	# undef __GENTOO_HAS_FEATURE
	#endif
	EOF

	if use hardened ; then
		cat >> "${ED}/etc/clang/gentoo-hardened.cfg" <<-EOF || die
			# Options below are conditional on USE=hardened.
			-D_GLIBCXX_ASSERTIONS

			# Analogue to GLIBCXX_ASSERTIONS
			# https://libcxx.llvm.org/UsingLibcxx.html#assertions-mode
			-D_LIBCPP_ENABLE_ASSERTIONS=1
		EOF
	fi

	local tool
	for tool in clang{,++,-cpp}; do
		newins - "${tool}.cfg" <<-EOF
			# This configuration file is used by ${tool} driver.
			@gentoo-common.cfg
		EOF
	done

	if use kernel_Darwin; then
		cat >> "${ED}/etc/clang/gentoo-common.cfg" <<-EOF || die
			# Gentoo Prefix on Darwin
			-Wl,-search_paths_first
			-Wl,-rpath,${EPREFIX}/usr/lib
			-L ${EPREFIX}/usr/lib
			-isystem ${EPREFIX}/usr/include
			-isysroot ${EPREFIX}/MacOSX.sdk
		EOF
		if use bootstrap-prefix ; then
			# bootstrap-prefix is only set during stage2 of bootstrapping
			# Prefix, where EPREFIX is set to EPREFIX/tmp.
			# Here we need to point it at the future lib dir of the stage3's
			# EPREFIX.
			cat >> "${ED}/etc/clang/gentoo-common.cfg" <<-EOF || die
				-Wl,-rpath,${EPREFIX}/../usr/lib
			EOF
		fi
		cat >> "${ED}/etc/clang/clang++.cfg" <<-EOF || die
			-lc++abi
		EOF
	fi
}

pkg_preinst() {
	if has_version -b sys-devel/gcc-config && has_version sys-devel/gcc
	then
		local gcc_path=$(gcc-config --get-lib-path 2>/dev/null)
		if [[ -n ${gcc_path} ]]; then
			cat >> "${ED}/etc/clang/gentoo-gcc-install.cfg" <<-EOF
				--gcc-install-dir="${gcc_path%%:*}"
			EOF
		fi
	fi
}
