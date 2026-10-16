# Print the scalar at a dotted key path of a pretty-printed JSON file.
#
#   awk -v want=engine.release -f tools/json-get.awk versions.json
#
# Exit status 1 when the path is not there. For versions.json, which the
# launcher and tools/flutter-sdk.sh read before any Dart exists on the machine:
# the launcher answers --version without Flutter, and flutter-sdk.sh is what
# downloads Flutter. The file must have one member per line, the way
# tools/publish-*.sh write it (json.dump, indent 2). Strings with escaped
# quotes are not handled; versions.json has none in the keys it reads.
BEGIN { depth = 0; found = 0 }
{
  line = $0
  sub(/^[ \t]+/, "", line)
  sub(/[ \t\r]+$/, "", line)
  if (line ~ /^[]}]/) { depth--; next }
  if (line ~ /^[{[]$/) { depth++; next }
  if (line !~ /^"[^"]*"[ \t]*:/) next
  key = line; sub(/^"/, "", key); sub(/".*/, "", key)
  rest = line; sub(/^"[^"]*"[ \t]*:[ \t]*/, "", rest)
  path[depth] = key
  p = path[1]
  for (i = 2; i <= depth; i++) p = p "." path[i]
  if (rest ~ /^[{[]/) {
    if (rest !~ /[]}],?$/) depth++
    next
  }
  if (p == want) {
    sub(/,$/, "", rest)
    if (rest ~ /^".*"$/) rest = substr(rest, 2, length(rest) - 2)
    if (rest == "null") rest = ""
    print rest
    found = 1
    exit
  }
}
END { exit !found }
