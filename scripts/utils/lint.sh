#!/bin/bash
# Lint of the flow scripts: shellcheck (shell), ruff (Python), tclint (Tcl, when it is installed)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: make lint, or scripts/utils/lint.sh in the repo root
# in:  the tracked *.sh, *.py and *.tcl files of scripts/, sim/ and config/
# out: the findings on stdout, exit 1 when a linter finds something
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# A linter that is not on PATH runs from nixpkgs. The settings are fixed here, so a user config does not change them.
run() {  # run <tool> <args...>
  if command -v "$1" > /dev/null; then "$@"; else nix shell "nixpkgs#$1" -c "$@"; fi
}
files() { git ls-files -- scripts sim config | grep -E "\.$1\$"; }
mapfile -t SH < <(files sh)
mapfile -t PY < <(files py)
mapfile -t TCL < <(files tcl)

rc=0
echo "[LINT] shellcheck"
run shellcheck -x --source-path=SCRIPTDIR --severity=warning "${SH[@]}" || rc=1
echo "[LINT] ruff"
run ruff check --quiet --isolated --select E,F,W --line-length 120 "${PY[@]}" || rc=1
if command -v tclint > /dev/null; then
  echo "[LINT] tclint"
  tclint "${TCL[@]}" || rc=1
else
  echo "[LINT] tclint not installed (pip install tclint): Tcl not checked"
fi
[ $rc = 0 ] && echo "[LINT] clean"
exit $rc
