# Rules for running alex and happy.
#
# Unlike hsc2hs, alex/happy don't ship with GHC - they're separate Hackage
# packages. buck2/gen-haskell-prebuilt.py asks Cabal where it put them
# (`cabal list-bin alex`/`happy`) and freezes the answer in
# third-party/haskell/tools.bzl, the same "Cabal identifies/builds it,
# buck2 just references the frozen result" approach third-party/haskell/BUCK
# uses for library packages. Re-run that script to pick up a version bump.

load("@third-party-haskell//:tools.bzl", "ALEX", "HAPPY")

def _run_tool_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)
    ctx.actions.run(
        cmd_args(ctx.attrs.tool, ctx.attrs.src, "-o", out.as_output()),
        category = ctx.attrs.category,
    )
    # GHC looks for a module's .hs-boot file next to its .hs file. For a
    # generated module the .hs lives in this rule's output directory, so
    # the boot file is copied there too and exposed as the sub-target
    # named after its path (e.g. `:rule[GHC/Parser.hs-boot]`), which
    # buck2/haskell.bzl's _resolve_src passes through unchanged.
    sub_targets = {}
    if ctx.attrs.boot != None:
        boot_out = ctx.actions.declare_output(ctx.attrs.boot_out)
        ctx.actions.copy_file(boot_out, ctx.attrs.boot)
        sub_targets[ctx.attrs.boot_out] = [DefaultInfo(default_output = boot_out)]
    return [DefaultInfo(default_output = out, sub_targets = sub_targets)]

_run_tool = rule(
    impl = _run_tool_impl,
    attrs = {
        "boot": attrs.option(attrs.source(), default = None),
        "boot_out": attrs.option(attrs.string(), default = None),
        "category": attrs.string(),
        "out": attrs.string(),
        "src": attrs.source(),
        "tool": attrs.string(),
    },
)

def alex(name, src, out, boot = None, boot_out = None):
    _run_tool(name = name, src = src, out = out, boot = boot, boot_out = boot_out, tool = ALEX, category = "alex")

def happy(name, src, out, boot = None, boot_out = None):
    _run_tool(name = name, src = src, out = out, boot = boot, boot_out = boot_out, tool = HAPPY, category = "happy")
