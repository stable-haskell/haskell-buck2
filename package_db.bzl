# A package db with the registrations of some Haskell libraries and of
# everything they depend on: the package.conf.d of a GHC installation
# built with buck2 (the stage 2 of a GHC build).
#
# Each haskell_library registers itself in a db of its own, with
# `${pkgroot}` paths relative to that db (see prelude/haskell/haskell.bzl,
# _make_package). The confs are copied here with `${pkgroot}` replaced by
# the absolute path of the library's output directory; then the db is
# recached with ghc-pkg, and every library is exposed, as in an
# installation (buck2 builds with explicit -package-id flags and registers
# them hidden). A library that two dbs register under the same name (the
# unit `rts` of a GHC build, see rts/BUCK) is taken from the first db.

load("@prelude//decls/toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:library_info.bzl", "HaskellLibraryInfoTSet")
load("@prelude//haskell:link_info.bzl", "HaskellLinkInfo")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo")
load("@prelude//linking:link_info.bzl", "LinkStyle")

_SCRIPT = """\
set -e
OUT="$1"; GHC_PKG="$2"; shift 2
mkdir -p "$OUT"
for db in "$@"; do
  root=$(realpath "$db/..")
  for conf in "$db"/*.conf; do
    name=$(basename "$conf")
    [ -e "$OUT/$name" ] || { sed -e "s|\\${pkgroot}|$root|g" -e "/^exposed:/d" "$conf"; echo "exposed: True"; } > "$OUT/$name"
  done
done
"$GHC_PKG" --package-db "$OUT" recache
"""

def _haskell_package_db_impl(ctx: AnalysisContext) -> list[Provider]:
    link_style = LinkStyle(ctx.attrs.link_style)
    children = []
    for dep in ctx.attrs.deps:
        li = dep.get(HaskellLinkInfo)
        if li != None:
            # a library built for one link style only serves the others
            children.append(li.info[link_style] if link_style in li.info else li.info.values()[0])
    libs = ctx.actions.tset(HaskellLibraryInfoTSet, children = children)
    dbs = {}
    for lib in libs.traverse():
        dbs[lib.db] = None
    out = ctx.actions.declare_output("package.conf.d", dir = True)
    script = ctx.actions.write("register.sh", _SCRIPT)
    toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    ctx.actions.run(
        cmd_args(["sh", script, out.as_output(), toolchain.packager] + list(dbs.keys())),
        category = "haskell_package_db",
    )
    return [DefaultInfo(default_output = out)]

haskell_package_db = rule(
    impl = _haskell_package_db_impl,
    attrs = {
        "deps": attrs.list(attrs.dep()),
        # the link style whose registrations are taken (`static` or
        # `static_pic`; a library has one db per style)
        "link_style": attrs.string(default = "static"),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)
