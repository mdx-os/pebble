# Mutation entries by area

`make mutation-check` reads `scripts/mutation-manifest.txt` and then every
`*.txt` here, sorted by name, as one list. New entries go here, in the file
for their area, so branches that add entries in different areas never touch
the same file. One file per area, for example `model.txt`, `relay.txt`,
`tasks.txt`, `cloud.txt`, `release.txt`, `guards.txt` or `ui.txt`. Make a
new one when no area fits.

Each entry is a block of lines, with a blank line between entries. Lines
starting with `#` are comments.

```
# What the entry breaks, and why its tests must notice.
test: nameOfATest anotherTest
file: Packages/PebbleKit/Sources/PebbleCore/CloudHelp.swift
perl: s~what the code says~what breaks it~
```

- `test:` the test functions that must fail once the file is broken. One line.
- `file:` the file to break, from the top of the repository. One line, and
  the file must exist.
- `perl:` a substitution run over the whole file at once, so it can span
  lines with `\n`. Use `~` as the delimiter. An entry that needs several
  changes gives one `perl:` line for each, applied in order, and every one
  must change the file.

`make mutation-manifest-check` (part of `make verify`) fails on a block
with no `test:`, `file:` or `perl:` line, a `file:` that is gone, or two
entries run together. `make mutation-check ONLY=nameOfATest` runs just the
entries whose tests match.
