# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load(
    "@prelude//cxx:preprocessor.bzl",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfoTSet",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_infos",
    "get_artifact_suffix",
    "is_ghc_compiled_src",
    "is_haskell_src",
    "output_extensions",
    "srcs_to_pairs",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
)
load("@prelude//utils:argfile.bzl", "at_argfile")

# The type of the return value of the `_compile()` function.
CompileResultInfo = record(
    objects = field(Artifact),
    hi = field(Artifact),
    stubs = field(Artifact),
    producing_indices = field(bool),
    # Output directory of each source compiled on its own because of
    # `per_src_flags` (keyed by the source's path in `srcs`); see compile().
    persrc_objects = field(dict, {}),
)

CompileArgsInfo = record(
    result = field(CompileResultInfo),
    srcs = field(cmd_args),
    args_for_cmd = field(cmd_args),
    args_for_file = field(cmd_args),
    # The args without the output directories (-odir, ...), for the
    # per-source compiles of compile(), and those sources.
    persrc_args = field(cmd_args),
    persrc_srcs = field(list),
    # False when nothing is passed to GHC's --make run (a header-only
    # package, see haskell.bzl): the run is skipped.
    has_srcs = field(bool),
)

PackagesInfo = record(
    exposed_package_args = cmd_args,
    packagedb_args = cmd_args,
    transitive_deps = field(HaskellLibraryInfoTSet),
)

def _package_flag(toolchain: HaskellToolchainInfo) -> str:
    if toolchain.support_expose_package:
        return "-expose-package"
    else:
        return "-package"

def get_packages_info(ctx: AnalysisContext, link_style: LinkStyle, specify_pkg_version: bool, enable_profiling: bool) -> PackagesInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    # A dependency built for one link style only (a stage-2 library, static
    # in every mode) serves the others too: the interfaces and the package
    # db are what matters here.
    def info_for(lib):
        infos = lib.prof_info if enable_profiling else lib.info
        return infos[link_style] if link_style in infos else infos[infos.keys()[0]]

    libs = ctx.actions.tset(
        HaskellLibraryInfoTSet,
        children = [info_for(lib) for lib in direct_deps_link_info],
    )

    # Only direct dependencies are exposed (below). `base` is not exposed
    # implicitly: a package that needs it depends on it (buck2/haskell.bzl
    # adds it to every target that is not itself a boot library), and the
    # boot libraries of a GHC build (ghc-prim, rts, ...) must not see it.
    package_flag = _package_flag(haskell_toolchain)
    exposed_package_args = cmd_args()

    packagedb_args = cmd_args()
    packagedb_set = {}

    for lib in libs.traverse():
        packagedb_set[lib.db] = None
        hidden_args = cmd_args(
            hidden = [
                lib.import_dirs.values(),
                lib.stub_dirs,
                # libs of dependencies might be needed at compile time if
                # we're using Template Haskell:
                lib.libs,
            ]
        )

        exposed_package_args.add(hidden_args)

        packagedb_args.add(hidden_args)

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling,
    )

    # Expose only the packages we depend on directly
    for lib in haskell_direct_deps_lib_infos:
        if lib.id:
            # Resolve by unit id rather than by name: unambiguous even when
            # another version of the same package is visible in another
            # package db (e.g. GHC's global db vs. a cabal-store rebuild of a
            # boot package such as time or directory, or a global Cabal
            # vs. one built from source here).
            exposed_package_args.add("-package-id", lib.id)
            continue

        pkg_name = lib.name
        if specify_pkg_version:
            pkg_name += "-{}".format(lib.version)

        exposed_package_args.add(package_flag, pkg_name)

    return PackagesInfo(
        exposed_package_args = exposed_package_args,
        packagedb_args = packagedb_args,
        transitive_deps = libs,
    )

def compile_args(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname = None, suffix: str = "", native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False) -> CompileArgsInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    compile_cmd = cmd_args()
    compile_cmd.add(haskell_toolchain.compiler_flags)

    # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
    # be parsed when inside an argsfile.
    compile_cmd.add(ctx.attrs.compiler_flags)

    compile_args = cmd_args()
    compile_args.add("-no-link", "-i")
    compile_args.add("-package-env=-")

    # Without this, GHC's own implicit global package db (always loaded,
    # independent of anything passed via -package-db below) leaks in
    # alongside the deps get_packages_info() computes - normally harmless
    # (nothing there collides with an ordinary project's own package
    # names), but GHC ships boot libraries under names a project can
    # itself build from source under the same name (e.g. `Cabal`,
    # `Cabal-syntax`) - then both the boot copy (auto-exposed globally)
    # and this target's own explicitly `-package-id`-exposed one export
    # the same module name, and GHC fails with "Ambiguous module name"
    # for any of that module's importers, even though the -package-id
    # given to *this* compile is perfectly unambiguous on its own.
    # get_packages_info() already computes exactly the exposure set this
    # compile needs (direct deps + base, see its own comment) - with
    # `-hide-all-packages` GHC uses only that, ignoring the global db's
    # own default exposure entirely.
    compile_args.add("-hide-all-packages")

    if enable_profiling:
        compile_args.add("-prof")

    if link_style == LinkStyle("shared"):
        compile_args.add("-dynamic", "-fPIC")
    elif link_style == LinkStyle("static_pic"):
        compile_args.add("-fPIC", "-fexternal-dynamic-refs")

    if dynamic_too:
        # Produces .dyn_o/.dyn_hi alongside this compile's ordinary .o/.hi,
        # in the same -odir/-hidir (the only way to get both from GHC in
        # --make mode - there's no flag to write them to different
        # directories). GHC guarantees these are consistent with the
        # primary .o/.hi, since they come from the same compile pass and
        # share its frontend work - unlike reusing an *independently*
        # compiled "shared" variant's interfaces would be, which carries no
        # such guarantee. See haskell.bzl's use of this (building a
        # library's static archive and shared library from a single
        # -dynamic-too compile instead of two independent ones) for why
        # this matters enough to ask for explicitly rather than just
        # tolerating two compiles.
        compile_args.add("-dynamic-too")
        # -dynamic-too compiles a C source once, to the ordinary .o: with
        # PIC it serves the shared library too (see _srcs_to_objfiles in
        # haskell.bzl).
        compile_args.add("-optc-fPIC", "-optcxx-fPIC")

    osuf, hisuf = output_extensions(link_style, enable_profiling)
    compile_args.add("-osuf", osuf, "-hisuf", hisuf)

    if getattr(ctx.attrs, "main", None) != None:
        compile_args.add(["-main-is", ctx.attrs.main])

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling, suffix)

    objects = ctx.actions.declare_output(
        "objects-" + artifact_suffix,
        dir = True,
        has_content_based_path = False,
    )
    hi = ctx.actions.declare_output("hi-" + artifact_suffix, dir = True, has_content_based_path = False)
    stubs = ctx.actions.declare_output("stubs-" + artifact_suffix, dir = True, has_content_based_path = False)

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.
    packages_info = get_packages_info(
        ctx,
        link_style,
        specify_pkg_version = False,
        enable_profiling = enable_profiling,
    )

    compile_args.add(packages_info.exposed_package_args)
    compile_args.add(packages_info.packagedb_args)

    # Add args from preprocess-able inputs.
    inherited_pre = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    pre = cxx_merge_cpreprocessors(ctx.actions, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    compile_args.add(cmd_args(pre_args, format = "-optP={}"))
    # The same for the C compiler: GHC compiles C sources given in srcs
    # (and the C stubs) with cc, which gets -optc flags, not -optP ones.
    compile_args.add(cmd_args(pre_args, format = "-optc{}"))

    if pkgname:
        compile_args.add(["-this-unit-id", pkgname])

    # Everything above also applies to a source compiled on its own (see
    # compile() and `per_src_flags`); the output directories below are
    # this --make run's own.
    persrc_args = compile_args.copy()

    compile_args.add(
        "-odir",
        objects.as_output(),
        "-hidir",
        hi.as_output(),
        "-hiedir",
        hi.as_output(),
        "-stubdir",
        stubs.as_output(),
    )

    per_src_flags = getattr(ctx.attrs, "per_src_flags", {})
    arg_srcs = []
    hidden_srcs = []
    persrc_srcs = []
    for path, src in srcs_to_pairs(ctx.attrs.srcs):
        # hs-boot files aren't expected to be an argument to compiler but does need
        # to be included in the directory of the associated src file
        if path in per_src_flags:
            persrc_srcs.append((path, src))
        elif is_ghc_compiled_src(path):
            arg_srcs.append(src)
        else:
            hidden_srcs.append(src)
    srcs = cmd_args(
        arg_srcs,
        hidden = hidden_srcs,
    )

    producing_indices = "-fwrite-ide-info" in ctx.attrs.compiler_flags

    if native_shared_libs_dir != None:
        # Template Haskell splices run *during* this compile action (not at
        # final-link time), and GHC resolves them by dlopen()-ing the actual
        # shared objects of every package involved - including, transitively,
        # any native (cxx_library) shared libraries a Haskell dependency
        # dynamically links against. The dynamic loader needs to find those
        # on its own search path right now, in this sandboxed process, or
        # dlopen fails with "cannot open shared object file" even though the
        # eventual link of this target would have resolved them fine via an
        # rpath. Pointing LD_LIBRARY_PATH at the same merged symlink tree
        # used for the final binary's rpath (see haskell_binary_impl /
        # _build_haskell_lib) covers this without needing to know in advance
        # which dependency, if any, actually uses Template Haskell.
        compile_args.add(cmd_args(hidden = native_shared_libs_dir))

    return CompileArgsInfo(
        result = CompileResultInfo(
            objects = objects,
            hi = hi,
            stubs = stubs,
            producing_indices = producing_indices,
        ),
        srcs = srcs,
        persrc_args = persrc_args,
        persrc_srcs = persrc_srcs,
        has_srcs = len(arg_srcs) > 0,
        args_for_cmd = compile_cmd,
        args_for_file = compile_args,
    )

# Compile all the context's sources.
def compile(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_shared_libs_dir: [Artifact, None] = None, dynamic_too: bool = False) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    compile_cmd = cmd_args(haskell_toolchain.compiler)

    args = compile_args(ctx, link_style, enable_profiling, pkgname, native_shared_libs_dir = native_shared_libs_dir, dynamic_too = dynamic_too)

    compile_cmd.add(args.args_for_cmd)

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    if args.args_for_file:
        if haskell_toolchain.use_argsfile:
            compile_cmd.add(
                at_argfile(
                    actions = ctx.actions,
                    name = artifact_suffix + ".haskell_compile_argsfile",
                    args = [args.args_for_file, args.srcs],
                    allow_args = True,
                )
            )
        else:
            compile_cmd.add(args.args_for_file)
            compile_cmd.add(args.srcs)

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    # compile_env's values are shell-evaluated (via `sh -c`) rather than
    # passed straight through as literal env values - this lets a value
    # like "$(clang -print-file-name=libclang_rt.asan-x86_64.so)" get
    # resolved fresh at actual build-action execution time, matching this
    # project's existing convention of resolving tools via $PATH at
    # build-action time rather than baking absolute host paths into .bzl
    # or BUCK files (see toolchains/BUCK's `compiler`/`packager`).
    env_exports = "".join([
        'export {}="{}"; '.format(name, value)
        for name, value in haskell_toolchain.compile_env.items()
    ]) if haskell_toolchain.compile_env else ""

    # The output directories are created first: GHC does not create -hidir
    # or -stubdir when nothing is written to them (a library of C and Cmm
    # sources only, such as GHC's rts), and an action must produce all its
    # declared outputs.
    outdirs = [args.result.objects.as_output(), args.result.hi.as_output(), args.result.stubs.as_output()]
    mkdirs = 'mkdir -p "$1" "$2" "$3"; shift 3; '

    build_tool_dirs = {
        dep[DefaultInfo].default_outputs[0].basename: dep[DefaultInfo].default_outputs[0]
        for dep in ctx.attrs.build_tool_depends
    }
    if build_tool_dirs:
        build_tool_bin_dir = ctx.actions.symlinked_dir(
            artifact_suffix + "-build-tool-depends",
            build_tool_dirs,
            has_content_based_path = False,
        )
        run_cmd = cmd_args(
            ["sh", "-c", mkdirs + env_exports + 'export PATH="$PATH:$1"; shift; exec "$@"', "sh"] + outdirs + [build_tool_bin_dir],
            compile_cmd,
        )
    else:
        run_cmd = cmd_args(["sh", "-c", mkdirs + env_exports + 'exec "$@"', "sh"] + outdirs, compile_cmd)

    if not args.has_srcs:
        # Nothing to compile (a header-only package): GHC would fail with
        # "no input files"; the output directories exist, empty.
        ctx.actions.run(
            cmd_args("mkdir", "-p", args.result.objects.as_output(), args.result.hi.as_output(), args.result.stubs.as_output()),
            category = "haskell_compile_" + artifact_suffix.replace("-", "_"),
        )
    else:
        ctx.actions.run(
            run_cmd,
            category = "haskell_compile_" + artifact_suffix.replace("-", "_"),
            # Keep the previous run's -odir/-hidir so that `ghc --make` can do its
            # own recompilation checking and only rebuild the modules whose
            # sources or imported interfaces changed, rather than the whole
            # package. GHC >= 9.4 tracks file changes with hashes rather than
            # timestamps, so this is safe even though Buck doesn't preserve
            # timestamps on artifacts.
            no_outputs_cleanup = True,
            env = {"LD_LIBRARY_PATH": cmd_args(native_shared_libs_dir)} if native_shared_libs_dir != None else {},
        )

    # A source with `per_src_flags` is compiled on its own, with the same
    # arguments plus its flags, into its own output directory (an action
    # cannot write into the --make run's output directories).
    # haskell.bzl's _srcs_to_objfiles takes its object from there.
    per_src_flags = getattr(ctx.attrs, "per_src_flags", {})
    persrc_objects = {}
    for path, src in args.persrc_srcs:
        odir = ctx.actions.declare_output(
            "objects-" + artifact_suffix + "-persrc-" + path.replace("/", "_"),
            dir = True,
            has_content_based_path = False,
        )
        persrc_cmd = cmd_args(
            haskell_toolchain.compiler,
            args.args_for_cmd,
            args.persrc_args,
            per_src_flags[path],
            "-c",
            src,
            "-odir",
            odir.as_output(),
            "-hidir",
            odir.as_output(),
            "-stubdir",
            odir.as_output(),
        )
        ctx.actions.run(
            persrc_cmd,
            category = "haskell_compile_persrc_" + artifact_suffix.replace("-", "_"),
            identifier = path,
            env = {"LD_LIBRARY_PATH": cmd_args(native_shared_libs_dir)} if native_shared_libs_dir != None else {},
        )
        persrc_objects[path] = odir

    return CompileResultInfo(
        objects = args.result.objects,
        hi = args.result.hi,
        stubs = args.result.stubs,
        producing_indices = args.result.producing_indices,
        persrc_objects = persrc_objects,
    )
