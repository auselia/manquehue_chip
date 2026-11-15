# Lists the make targets for make help (## only) and make help-all (## and ###)
# Author: Nicolás Villegas - Universidad de los Andes, Chile
# usage: awk [-v all=1] -f scripts/utils/help.awk Makefile scripts/*/module.mk
# in:  "target: ... ## text" lines, "#: name ## text" lines (targets made by a rule template), "##@ title" lines
# out: stdout
/^##@ / { title = substr($0, 5); next }
/^#: / || /^[a-zA-Z0-9_%-]+:.*##/ {
  i = index($0, "##")
  doc = substr($0, i)
  if (doc ~ /^###/ && !all) next
  sub(/^###? */, "", doc)
  name = /^#: / ? substr($0, 4, i - 5) : substr($0, 1, index($0, ":") - 1)
  sub(/ +$/, "", name)
  if (title != "") { printf "\n%s\n", title; title = "" }
  printf "  make %-20s %s\n", name, doc
}
