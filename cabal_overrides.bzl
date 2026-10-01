# Helper for the BUCK.cabal.bzl files that `cabal buck2` generates.
#
# `generated_targets(overrides = {...})` lets a hand-maintained BUCK file
# extend a generated rule without a copy of the generated call. `overrides`
# maps a target name to keyword arguments to merge into that target's call:
# lists are appended, dicts are merged (the override wins on a common key),
# any other value is replaced. See README.md, "Extending a generated target".

def apply_overrides(overrides, kwargs):
    for k, v in overrides.get(kwargs["name"], {}).items():
        old = kwargs.get(k)
        if type(old) == type([]) and type(v) == type([]):
            kwargs[k] = old + v
        elif type(old) == type({}) and type(v) == type({}):
            merged = dict(old)
            merged.update(v)
            kwargs[k] = merged
        else:
            kwargs[k] = v
    return kwargs
