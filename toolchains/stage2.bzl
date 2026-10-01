# Stage 2 of a bootstrapped compiler (see ../constraints/BUCK): in the
# `stage2` configuration the Haskell toolchain runs tools that this very
# project builds (wrappers around its stage-1 compiler), named in
# .buckconfig:
#
#   [haskell_stage2]
#     compiler = root//buck2-ghc:ghc
#     packager = root//buck2-ghc:ghc-pkg
#     hsc2hs = root//buck2-ghc:hsc2hs
#
# Each is an exec_dep (built with the boot toolchain), selected only under
# the stage2 constraint; without the section the toolchain is unchanged.

def stage2_tool(key):
    label = read_root_config("haskell_stage2", key, None)
    if label == None:
        return None
    return select({
        "root//buck2/constraints:stage2": label,
        "DEFAULT": None,
    })
