# Helper for the BUCK.cabal.bzl files that `cabal buck2` generates.
#
# `generated_targets(overrides = {...})` lets a hand-maintained BUCK file
# extend a generated rule without a copy of the generated call. `overrides`
# maps a target name to keyword arguments to merge into that target's call:
# lists are appended, dicts are merged (the override wins on a common key),
# any other value is replaced. A list may hold `remove([...])` entries,
# which take items out of the generated list:
#
#   "deps": [remove(["//rts:rts-stage2"]), ":rts-constants-stage2"]
#
# See README.md, "Extending a generated target".

def remove(items):
    """An entry of a list override that removes `items` from the generated list."""
    return struct(removed = items)

def _is_removal(x):
    return type(x) == type(struct()) and hasattr(x, "removed")

def apply_overrides(overrides, kwargs):
    for k, v in overrides.get(kwargs["name"], {}).items():
        old = kwargs.get(k)
        if type(v) == type([]) and (old == None or type(old) == type([])):
            removed = [x for r in v if _is_removal(r) for x in r.removed]
            kwargs[k] = [x for x in (old or []) if x not in removed] + [x for x in v if not _is_removal(x)]
        elif type(old) == type({}) and type(v) == type({}):
            merged = dict(old)
            merged.update(v)
            kwargs[k] = merged
        else:
            kwargs[k] = v
    return kwargs
