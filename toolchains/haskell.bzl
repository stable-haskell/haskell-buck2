load("@prelude//haskell:toolchain.bzl", "HaskellPlatformInfo", "HaskellToolchainInfo")

def _tool(exe_dep, name):
    # A buck2-built tool (exec_dep with RunInfo) wins over a name looked up
    # on $PATH at build-action time.
    return exe_dep[RunInfo] if exe_dep != None else name

def _haskell_toolchain_impl(ctx):
    compiler = _tool(ctx.attrs.compiler_exe, ctx.attrs.compiler)
    return [
        DefaultInfo(),
        HaskellToolchainInfo(
            compiler = compiler,
            packager = _tool(ctx.attrs.packager_exe, ctx.attrs.packager),
            hsc2hs = _tool(ctx.attrs.hsc2hs_exe, ctx.attrs.hsc2hs),
            linker = compiler,
            haddock = ctx.attrs.haddock,
            compiler_flags = ctx.attrs.compiler_flags,
            linker_flags = ctx.attrs.linker_flags,
            compile_env = ctx.attrs.compile_env,
            dynamic_ghc = ctx.attrs.dynamic_ghc,
        ),
        HaskellPlatformInfo(name = host_info().arch),
    ]

haskell_toolchain = rule(
    impl = _haskell_toolchain_impl,
    attrs = {
        "compiler": attrs.string(default = "ghc"),
        "packager": attrs.string(default = "ghc-pkg"),
        # hsc2hs: None derives `hsc2hs-<version>` from `compiler`.
        "hsc2hs": attrs.option(attrs.string(), default = None),
        # buck2-built alternatives to the three names above, e.g. a wrapper
        # around a compiler built by this very project (GHC's stage 2).
        "compiler_exe": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
        "packager_exe": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
        "hsc2hs_exe": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
        "haddock": attrs.string(default = "haddock"),
        "compiler_flags": attrs.list(attrs.string(), default = []),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "compile_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # Whether the `compiler` above is itself dynamically linked -
        # see buck2/gen-haskell-prebuilt.py's own `_ghc_dynamic()` for
        # how this gets discovered (not assumed), and buck2/prelude/
        # haskell/haskell.bzl's own uses of `haskell_toolchain.
        # dynamic_ghc` for what it actually gates.
        "dynamic_ghc": attrs.bool(default = True),
    },
    is_toolchain_rule = True,
)
