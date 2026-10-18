#!/bin/sh
# Fails when a code comment carries the history of a review or a person's
# name. A comment says what the code, or the test, protects; who asked for
# it and in which round belongs in the pull request, not in the code.
#
# Checks comments for:
# - "fix round", in any case
# - review item and round numbers, like "item 11" or "round 4"
# - any name in the list of names, in any case, also as a possessive; a
#   name of two words matches with any space between
# Comments are // and /* */ in Swift, every line of a block included; #
# in scripts, Makefile and YAML; and lines that start with # in text files
# such as the mutation manifest. Text inside quotes is not a comment, so a
# string such as "https://example.com/item 3" passes.
#
# The list of names holds only the names the lint needs, one per line, so
# a comment can never name the people who direct this work. Blank lines
# and lines starting with # are skipped. The real names are never in the
# repository: the list is the file COMMENT_LINT_NAMES names, as CI gives
# it, or else Config/comment-lint-names.local.txt, which git ignores. With
# neither, only review history is checked, and the run says so.
#
# Usage: scripts/comment-lint.sh [path...]   (default: the code folders)
#        scripts/comment-lint.sh --self-test
# The self-test makes up a list of its own, so it never needs the real one.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
local_names="$here/../Config/comment-lint-names.local.txt"
if [ -n "${COMMENT_LINT_NAMES:-}" ]; then
  names="$COMMENT_LINT_NAMES"
  if [ ! -r "$names" ]; then
    echo "comment-lint: can't read the list of names in $names"
    exit 1
  fi
elif [ -r "$local_names" ]; then
  names="$local_names"
else
  names=/dev/null
fi

# Reads file names on stdin, one per line, and prints every comment that
# matches as file:line:text. Exits 1 on a match, 2 when a file can't be read.
scan() {
  perl -e '
    use strict; use warnings;
    my ($names) = @ARGV;
    open(my $nf, "<", $names) or exit 2;
    my @people;
    while (my $name = <$nf>) {
      chomp $name;
      $name =~ s/^\s+|\s+$//g;
      next if $name eq "" || $name =~ /^#/;
      my $quoted = join("\\s+", map { quotemeta } split(/\s+/, $name));
      push @people, $quoted;
    }
    my $pattern = q{fix(?:ed)?\s+round|(?<![\w])(?:item|round)\s+[0-9]+};
    $pattern .= q{|(?<![\w])(?:} . join("|", @people) . q{)} if @people;
    my $match = qr/$pattern/i;
    # A string in double quotes, escapes and all. Never a comment.
    my $quoted = qr/"(?:[^"\\]|\\.)*"/;
    my $found = 0;
    while (my $file = <STDIN>) {
      chomp $file;
      next if $file eq "";
      my $kind = $file =~ /\.swift$/ ? "swift" : $file =~ /\.txt$/ ? "text" : "hash";
      open(my $fh, "<", $file) or do { print "comment-lint: can'"'"'t read $file\n"; exit 2 };
      my $block = 0;
      my $n = 0;
      while (my $line = <$fh>) {
        $n++;
        chomp $line;
        my $comment = "";
        if ($kind eq "swift") {
          my $rest = $line;
          $rest =~ s/$quoted/""/g;
          while (length $rest) {
            if ($block) {
              if ($rest =~ m{^(.*?)\*/(.*)$}) { $comment .= " $1"; $rest = $2; $block = 0 }
              else { $comment .= " $rest"; $rest = "" }
            } elsif ($rest =~ m{^.*?(//|/\*)(.*)$}) {
              if ($1 eq "//") { $comment .= " $2"; $rest = "" } else { $rest = $2; $block = 1 }
            } else { $rest = "" }
          }
        } elsif ($kind eq "text") {
          $comment = $line if $line =~ /^\s*#/;
        } else {
          my $rest = $line;
          $rest =~ s/$quoted|\x27[^\x27]*\x27//g;
          $rest =~ s/\$\{?#//g;
          $comment = $1 if $rest =~ /#(.*)$/;
        }
        if ($comment =~ $match) { print "$file:$n:$line\n"; $found = 1 }
      }
      close $fh;
    }
    exit $found;
  ' "$names"
}

self_test() {
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' EXIT
  # Built from pieces, so this script never holds the words it looks for.
  fix="Fix"
  round="round"
  item="item"
  mkdir -p "$dir/bad" "$dir/good"
  printf '    // MARK: %s %s 5\n' "$fix" "$round" > "$dir/bad/mark.swift"
  printf '    // MARK: %s %s\n' "FIXED" "ROUND" > "$dir/bad/caps.swift"
  printf '    // %s %s 5\n' "fix" "ROUND" > "$dir/bad/mixed.swift"
  printf '/// Asked for in %s 11.\nlet x = 1\n' "$item" > "$dir/bad/item.swift"
  printf 'let x = 1 // since %s 4\n' "$round" > "$dir/bad/trailing.swift"
  printf '/* %s %s 2 */\n' "$fix" "$round" > "$dir/bad/block.swift"
  printf '/*\n * What this guards.\n * %s %s 3\n */\nlet x = 1\n' "$fix" "$round" > "$dir/bad/continued.swift"
  printf '/**\n   carried over from %s 7\n */\n' "$item" > "$dir/bad/bare.swift"
  printf '# %s %s 3 asked for this\n' "$fix" "$round" > "$dir/bad/script.sh"
  printf 'build: # %s %s 3\n' "$fix" "$round" > "$dir/bad/Makefile"
  printf 'targets: # since %s 2\n' "$round" > "$dir/bad/project.yml"
  printf '# %s %s 4 follow-ups\ntest: aTest\n' "$fix" "$round" > "$dir/bad/manifest.txt"
  # A made-up list, so the self-test never needs the real one: a header,
  # a name of two words, one with a regex symbol, and a plain one.
  printf '# A header line, never a name.\n\nAda Byron\nJo.Ann\nQuillon\n' > "$dir/names.txt"
  COMMENT_LINT_NAMES="$dir/names.txt"
  export COMMENT_LINT_NAMES
  # Every name in the list, plain, in lower case and as a possessive.
  count=0
  while IFS= read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    count=$((count + 1))
    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    printf '/// %s decided this.\n' "$name" > "$dir/bad/name$count.swift"
    printf '/// thanks to %s\n' "$lower" > "$dir/bad/lower$count.swift"
    printf "// %s's call\n" "$name" > "$dir/bad/possessive$count.swift"
    printf '# from %s\n' "$name" > "$dir/bad/name$count.sh"
  done < "$dir/names.txt"
  # Fine: words that only look alike, and the same words outside a comment.
  printf '/// Rounds to 4 places, and lists items 1 to 3.\nlet rounded = 4\n' > "$dir/good/words.swift"
  printf '#expect(text.contains("%s %s 5"))\n' "$fix" "$round" > "$dir/good/string.swift"
  printf 'let url = "https://example.com" // the sample address\n' > "$dir/good/url.swift"
  printf 'let url = "https://example.com/%s 3"\n' "$item" > "$dir/good/path.swift"
  printf 'let a = 2 * 3\n/* a\n * product */\n' > "$dir/good/product.swift"
  printf '# Retries round the clock, item by item.\nexit 0\n' > "$dir/good/script.sh"
  printf 'echo "%s %s 4"\n[ "$#" -gt 0 ] || echo "%s 5"\n' "$fix" "$round" "$item" > "$dir/good/quoted.sh"
  printf 'perl: s~%s %s 3~x~\n' "$fix" "$round" > "$dir/good/manifest.txt"
  failed=0
  for bad in "$dir"/bad/*; do
    if sh "$0" "$bad" >/dev/null 2>&1; then
      echo "comment-lint self-test: missed $(basename "$bad"): $(cat "$bad")"
      failed=1
    fi
  done
  if ! sh "$0" "$dir/good" >/dev/null 2>&1; then
    echo "comment-lint self-test: flagged a fine comment:"
    sh "$0" "$dir/good" || true
    failed=1
  fi
  # A name of two words matches across any space; a symbol in a name is
  # only itself.
  printf '// asked by Ada  Byron\n' > "$dir/two.swift"
  printf '// JoXAnn is a made-up word\n' > "$dir/symbol.swift"
  if sh "$0" "$dir/two.swift" >/dev/null 2>&1; then
    echo "comment-lint self-test: missed a name of two words"
    failed=1
  fi
  if ! sh "$0" "$dir/symbol.swift" >/dev/null 2>&1; then
    echo "comment-lint self-test: read a dot in a name as any letter"
    failed=1
  fi
  # A list it was told to read but can't is an error, never an empty list.
  if COMMENT_LINT_NAMES="$dir/nowhere.txt" sh "$0" "$dir/good" >/dev/null 2>&1; then
    echo "comment-lint self-test: ran without the list it was given"
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then exit 1; fi
  echo "comment-lint self-test: ok"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

[ "$#" -gt 0 ] || set -- Packages/PebbleKit/Sources Packages/PebbleKit/Tests App AppUITests scripts project.yml Makefile

for path in "$@"; do
  if [ ! -e "$path" ]; then
    echo "comment-lint: can't find $path"
    exit 1
  fi
done

status=0
hits="$(find "$@" -type f \( -name '*.swift' -o -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name '*.txt' \
  -o -name Makefile \) ! -path '*/.build/*' ! -name 'comment-lint.sh' ! -name 'comment-lint-names*.txt' | sort | scan)" \
  || status=$?
if [ "$status" -eq 1 ]; then
  echo "comment-lint: say what the code protects, not the review it came from or who asked:"
  printf '%s\n' "$hits"
  exit 1
elif [ "$status" -ne 0 ]; then
  printf '%s\n' "$hits"
  echo "comment-lint: couldn't read every file"
  exit 1
fi
if [ "$names" = /dev/null ]; then
  echo "comment-lint: ok (review history only; no list of names, so names weren't checked)"
else
  echo "comment-lint: ok"
fi
