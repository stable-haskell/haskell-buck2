# A Haskell module copied to the path its module name implies, together
# with its .hs-boot file.
#
# GHC looks for a module's .hs-boot file next to its .hs file. A module
# that does not live at its module path (hs-source-dirs: src) is copied
# there by buck2/haskell.bzl; when it has a boot file, the two must land
# in the same output directory, so one rule copies both. The boot file is
# the sub-target named after its path (e.g. `:rule[GHC/Exception.hs-boot]`),
# as in alex_happy.bzl and hsc2hs.bzl.

def _module_copy_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)
    ctx.actions.copy_file(out, ctx.attrs.src)
    boot_out = ctx.actions.declare_output(ctx.attrs.boot_out)
    ctx.actions.copy_file(boot_out, ctx.attrs.boot)
    return [DefaultInfo(default_output = out, sub_targets = {ctx.attrs.boot_out: [DefaultInfo(default_output = boot_out)]})]

module_copy = rule(
    impl = _module_copy_impl,
    attrs = {
        "boot": attrs.source(),
        "boot_out": attrs.string(),
        "out": attrs.string(),
        "src": attrs.source(),
    },
)
