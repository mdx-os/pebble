#!/bin/sh
# Fails when a code comment carries the history of a review or a person's
# name. A comment says what the code, or the test, protects; who asked for
# it and in which round belongs in the pull request, not in the code.
#
# Checks comments for:
# - "fix round", in any case
# - review item and round numbers, like "item 11", "round 4", "Round-4"
#   or "round #4", and numbered fixes like "fix9"
# - any name in the list of names, in any case, also as a possessive; a
#   name of two words matches with any space between
# Comments are // and /* */ in Swift, every line of a block included; #
# in scripts, Makefile and YAML; and lines that start with # in text files
# such as the mutation manifest. A string in quotes outside a comment is
# not a comment, so "https://example.com/item 3" in code passes; quotes
# inside a comment are part of it and are checked.
#
# The names are never in the repository, in plain text or in any other
# form: a hash of a short name can be undone by trying every name. The
# list is a plain file kept outside the repository, and COMMENT_LINT_NAMES
# names it: one name of one or two words per line, blank lines and lines
# starting with # skipped. When COMMENT_LINT_NAMES is unset or empty the
# names are not checked, and the lint says so; review history is checked
# everywhere either way. A COMMENT_LINT_NAMES that names a file that can't
# be read, or holds a name of more than two words, is an error. A match
# gives the file and line, never the name.
#
# The lint splits each comment into words (letters, digits and
# apostrophes, in lower case, a trailing 's dropped) and looks up each
# word, and each word with the next, among the names split the same way.
#
# Usage: COMMENT_LINT_NAMES=/path/to/names.txt scripts/comment-lint.sh [path...]
#          (default: the code folders)
#        scripts/comment-lint.sh --self-test
# The self-test makes up names of its own, so it never needs the real ones.
set -eu

names_file="${COMMENT_LINT_NAMES:-}"

# Reads file names on stdin, one per line, and prints every comment that
# matches: file:line:text for review history, and for a name only
# file:line, so the log never holds the name. Exits 1 on a match, 2 when a
# file can't be read, 3 when the names list can't be used.
scan() {
  perl -e '
    use strict; use warnings;
    # The words of a text: letters, digits and apostrophes, in lower case,
    # with a trailing possessive and stray apostrophes dropped.
    sub words_of {
      my ($text) = @_;
      utf8::decode($text);
      my @words;
      for my $word (lc($text) =~ /[\p{L}\p{N}\x27\x{2019}]+/g) {
        $word =~ s/[\x27\x{2019}]s$//;
        $word =~ s/^[\x27\x{2019}]+|[\x27\x{2019}]+$//g;
        push @words, $word if length $word;
      }
      return @words;
    }
    my ($names) = @ARGV;
    my %set;
    if ($names ne "") {
      open(my $fh, "<", $names) or do { print "comment-lint: can\x27t read the names list COMMENT_LINT_NAMES names\n"; exit 3 };
      my $n = 0;
      while (my $line = <$fh>) {
        $n++;
        next if $line =~ /^\s*(#|$)/;
        my @words = words_of($line);
        next unless @words;
        if (@words > 2) { print "comment-lint: line $n of the names list has more than two words, and the lint matches one or two\n"; exit 3 }
        $set{join(" ", @words)} = 1;
      }
      if (!%set) { print "comment-lint: the names list COMMENT_LINT_NAMES names holds no names\n"; exit 3 }
    }
    my $history = qr/fix(?:ed)?\s+round|(?<![\w])(?:item|round)[\s#-]*[0-9]+|(?<![\w])fix[0-9]+(?![\w])/i;
    # A string in double quotes, escapes and all. Never a comment.
    my $quoted = qr/"(?:[^"\\]|\\.)*"/;
    my $found = 0;
    while (my $file = <STDIN>) {
      chomp $file;
      next if $file eq "";
      my $kind = $file =~ /\.swift$/ ? "swift" : $file =~ /\.txt$/ ? "text" : "hash";
      open(my $fh, "<", $file) or do { print "comment-lint: can\x27t read $file\n"; exit 2 };
      my $block = 0;
      # Inside a Swift string of several lines, between two """.
      my $multi = 0;
      my $n = 0;
      while (my $line = <$fh>) {
        $n++;
        chomp $line;
        my $comment = "";
        if ($kind eq "swift") {
          my $rest = $line;
          if ($multi) {
            if ($rest =~ /"""(.*)$/) { $rest = $1; $multi = 0 } else { $rest = "" }
          }
          # A """ outside a comment opens a string that runs to the next
          # one, maybe lines on, and nothing in it is a comment.
          if (!$block && $rest =~ /^(.*?)"""(.*)$/) {
            my ($before, $after) = ($1, $2);
            (my $code = $before) =~ s/$quoted/""/g;
            unless ($code =~ m{//|/\*}) {
              $rest = $before;
              if ($after =~ /"""(.*)$/) { $rest .= " $1" } else { $multi = 1 }
            }
          }
          # Read left to right, so a string is skipped only outside a
          # comment, and quotes inside one are part of the comment.
          while (length $rest) {
            if ($block) {
              if ($rest =~ m{^(.*?)\*/(.*)$}) { $comment .= " $1"; $rest = $2; $block = 0 }
              else { $comment .= " $rest"; $rest = "" }
            } elsif ($rest =~ m{^.*?(//|/\*|")(.*)$}) {
              my ($open, $after) = ($1, $2);
              if ($open eq "//") { $comment .= " $after"; $rest = "" }
              elsif ($open eq "/*") { $rest = $after; $block = 1 }
              else { $rest = $after =~ /^(?:[^"\\]|\\.)*"(.*)$/ ? $1 : "" }
            } else { $rest = "" }
          }
        } elsif ($kind eq "text") {
          $comment = $line if $line =~ /^\s*#/;
        } else {
          # The same, for a # comment: strings and $# before it are
          # skipped, and everything after it is the comment.
          my $rest = $line;
          while ($rest =~ /^.*?(\$\{?#|#|"|\x27)(.*)$/) {
            my ($open, $after) = ($1, $2);
            if ($open eq "#") { $comment = $after; last }
            elsif ($open eq "\"") { $rest = $after =~ /^(?:[^"\\]|\\.)*"(.*)$/ ? $1 : "" }
            elsif ($open eq "\x27") { $rest = $after =~ /^[^\x27]*\x27(.*)$/ ? $1 : "" }
            else { $rest = $after }
          }
        }
        my @words = words_of($comment);
        my @keys = (@words, map { "$words[$_] $words[$_ + 1]" } 0 .. $#words - 1);
        if (grep { $set{$_} } @keys) { print "$file:$n: a name from the list\n"; $found = 1 }
        elsif ($comment =~ $history) { print "$file:$n:$line\n"; $found = 1 }
      }
      close $fh;
    }
    exit $found;
  ' "$1"
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
  printf '// since %s-4\n' "Round" > "$dir/bad/hyphen.swift"
  printf '// since %s #4\n' "Round" > "$dir/bad/hash.swift"
  printf '// carried from %s#2\n' "$item" > "$dir/bad/hashtight.swift"
  printf '# ported from %s9\ntest: aTest\n' "$fix" > "$dir/bad/numberedfix.txt"
  printf '/* %s %s 2 */\n' "$fix" "$round" > "$dir/bad/block.swift"
  printf '/*\n * What this guards.\n * %s %s 3\n */\nlet x = 1\n' "$fix" "$round" > "$dir/bad/continued.swift"
  printf '/**\n   carried over from %s 7\n */\n' "$item" > "$dir/bad/bare.swift"
  printf '# %s %s 3 asked for this\n' "$fix" "$round" > "$dir/bad/script.sh"
  printf 'build: # %s %s 3\n' "$fix" "$round" > "$dir/bad/Makefile"
  printf 'targets: # since %s 2\n' "$round" > "$dir/bad/project.yml"
  printf '# %s %s 4 follow-ups\ntest: aTest\n' "$fix" "$round" > "$dir/bad/manifest.txt"
  # Made-up names, in a list outside the folders it checks.
  printf '# Made up for the self-test.\n\nAda  Byron\nQuillon\n' > "$dir/names.txt"
  printf '/// Ada Byron decided this.\n' > "$dir/bad/name.swift"
  printf '/// thanks to ada byron\n' > "$dir/bad/lower.swift"
  printf '/// QUILLON decided this.\n' > "$dir/bad/upper.swift"
  printf "// Quillon's call\n" > "$dir/bad/possessive.swift"
  printf '// Quillon\342\200\231s call\n' > "$dir/bad/curly.swift"
  printf '// asked by Ada   Byron\n' > "$dir/bad/spaces.swift"
  printf '// asked by Ada\tByron\n' > "$dir/bad/tab.swift"
  printf '/* for ADA BYRON\047S sake */\n' > "$dir/bad/twopossessive.swift"
  printf '# from Ada Byron\n' > "$dir/bad/name.sh"
  # Quotes inside a comment are still the comment.
  printf '    // "%s %s 4"\n' "$fix" "$round" > "$dir/bad/quotedcomment.swift"
  printf 'let x = "a" // since "%s 4"\n' "$round" > "$dir/bad/quotedtrailing.swift"
  printf '/* asked in "%s 2" */\n' "$item" > "$dir/bad/quotedblock.swift"
  printf '/// "Quillon" decided this.\n' > "$dir/bad/quotedname.swift"
  printf '# "%s %s 4"\n' "$fix" "$round" > "$dir/bad/quotedcomment.sh"
  printf 'echo "a" # from \047Ada Byron\047\n' > "$dir/bad/singlequoted.sh"
  printf '# a note for quillon\ntest: aTest\n' > "$dir/bad/name.txt"
  # Fine: words that only look alike, and the same words outside a comment.
  printf '/// Rounds to 4 places, and lists items 1 to 3.\nlet rounded = 4\n' > "$dir/good/words.swift"
  printf '/// A round trip, a prefix9 and a fixture2 are not review history.\n' > "$dir/good/near.history.swift"
  printf '#expect(text.contains("%s %s 5"))\n' "$fix" "$round" > "$dir/good/string.swift"
  printf 'let url = "https://example.com" // the sample address\n' > "$dir/good/url.swift"
  printf 'let url = "https://example.com/%s 3"\n' "$item" > "$dir/good/path.swift"
  printf 'let a = 2 * 3\n/* a\n * product */\n' > "$dir/good/product.swift"
  printf 'let text = """\n  https://example.com/%s 3\n  """\n' "$item" > "$dir/good/multiline.swift"
  printf 'let text = """\n  https://example.com\n  """ // since %s 4\n' "$round" > "$dir/bad/aftermultiline.swift"
  printf '# Retries round the clock, item by item.\nexit 0\n' > "$dir/good/script.sh"
  printf 'echo "%s %s 4"\n[ "$#" -gt 0 ] || echo "%s 5"\n' "$fix" "$round" "$item" > "$dir/good/quoted.sh"
  printf 'perl: s~%s %s 3~x~\n' "$fix" "$round" > "$dir/good/manifest.txt"
  printf '/// Quill, Quillons and Quillonade only look like a name.\n' > "$dir/good/near.swift"
  printf '/// Ada alone, Byron alone, or Adabyron, are no name.\n' > "$dir/good/apart.swift"
  printf 'let who = "Quillon" // the sample\n' > "$dir/good/quotedname.swift"
  printf 'echo "Ada Byron"\n' > "$dir/good/quotedname.sh"
  failed=0
  for bad in "$dir"/bad/*; do
    if COMMENT_LINT_NAMES="$dir/names.txt" sh "$0" "$bad" >/dev/null 2>&1; then
      echo "comment-lint self-test: missed $(basename "$bad")"
      failed=1
    fi
  done
  if ! COMMENT_LINT_NAMES="$dir/names.txt" sh "$0" "$dir/good" >/dev/null 2>&1; then
    echo "comment-lint self-test: flagged a fine comment:"
    COMMENT_LINT_NAMES="$dir/names.txt" sh "$0" "$dir/good" || true
    failed=1
  fi
  # A match says where, never the name.
  if COMMENT_LINT_NAMES="$dir/names.txt" sh "$0" "$dir/bad/name.swift" 2>&1 | grep -qi 'byron'; then
    echo "comment-lint self-test: printed the name it found"
    failed=1
  fi
  # With no list, review history still fails, a name passes, and the lint
  # says the names were not checked.
  if COMMENT_LINT_NAMES= sh "$0" "$dir/bad/mark.swift" >/dev/null 2>&1; then
    echo "comment-lint self-test: with no names list, missed review history"
    failed=1
  fi
  if ! COMMENT_LINT_NAMES= sh "$0" "$dir/bad/name.swift" 2>&1 | grep -q 'names were not checked'; then
    echo "comment-lint self-test: with no names list, didn't say the names were not checked"
    failed=1
  fi
  # A list that can't be read, holds a name of three words, or holds no
  # names is an error.
  printf 'Ada Lovelace Byron\n' > "$dir/three.txt"
  printf '# nothing\n\n' > "$dir/empty.txt"
  for broken in nowhere three empty; do
    if COMMENT_LINT_NAMES="$dir/$broken.txt" sh "$0" "$dir/good" >/dev/null 2>&1; then
      echo "comment-lint self-test: ran with a broken names list ($broken)"
      failed=1
    fi
  done
  # A folder the lint can't list fails it, never passes with its files
  # left unread.
  mkdir -p "$dir/unlisted/shut"
  printf '/// %s %s 5\n' "$fix" "$round" > "$dir/unlisted/shut/hidden.swift"
  chmod 000 "$dir/unlisted/shut"
  if COMMENT_LINT_NAMES= sh "$0" "$dir/unlisted" >/dev/null 2>&1; then
    echo "comment-lint self-test: passed a folder it couldn't list"
    failed=1
  fi
  chmod 755 "$dir/unlisted/shut"
  # A list inside the repository is refused, in a copy of the lint whose
  # repository is a scratch folder.
  mkdir -p "$dir/repo/scripts" "$dir/repo/Config"
  cp "$0" "$dir/repo/scripts/comment-lint.sh"
  cp "$dir/names.txt" "$dir/repo/Config/names.txt"
  if COMMENT_LINT_NAMES="$dir/repo/Config/names.txt" sh "$dir/repo/scripts/comment-lint.sh" "$dir/good" >/dev/null 2>&1; then
    echo "comment-lint self-test: took a names list from inside the repository"
    failed=1
  fi
  if ! COMMENT_LINT_NAMES="$dir/names.txt" sh "$dir/repo/scripts/comment-lint.sh" "$dir/good" >/dev/null 2>&1; then
    echo "comment-lint self-test: refused a names list outside the repository"
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then exit 1; fi
  echo "comment-lint self-test: ok"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

# A list inside the repository could be committed with it, so it is
# refused, ignored by git or not.
if [ -n "$names_file" ] && [ -e "$names_file" ]; then
  repo="$(cd "$(dirname "$0")/.." && pwd -P)"
  where="$(cd "$(dirname "$names_file")" && pwd -P)"
  case "$where/" in
    "$repo"/*)
      echo "comment-lint: the names list is inside the repository; keep it outside, where it can't be committed"
      exit 1
      ;;
  esac
fi

[ "$#" -gt 0 ] || set -- Packages/PebbleKit/Sources Packages/PebbleKit/Tests Tools/GuardKit App AppUITests scripts project.yml Makefile

for path in "$@"; do
  if [ ! -e "$path" ]; then
    echo "comment-lint: can't find $path"
    exit 1
  fi
done

# Listed into a file first, so a folder find can't read fails the lint,
# where a pipe would quietly leave its files out.
list="$(mktemp)"
trap 'rm -f "$list"' EXIT
if ! find "$@" -type f \( -name '*.swift' -o -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name '*.txt' \
  -o -name Makefile \) ! -path '*/.build/*' ! -name 'comment-lint.sh' > "$list"; then
  echo "comment-lint: couldn't list every file"
  exit 1
fi
status=0
hits="$(sort "$list" | scan "$names_file")" || status=$?
if [ "$status" -eq 1 ]; then
  echo "comment-lint: say what the code protects, not the review it came from or who asked:"
  printf '%s\n' "$hits"
  exit 1
elif [ "$status" -eq 3 ]; then
  printf '%s\n' "$hits"
  echo "comment-lint: the names list can't be used, so nothing was checked"
  exit 1
elif [ "$status" -ne 0 ]; then
  printf '%s\n' "$hits"
  echo "comment-lint: couldn't read every file"
  exit 1
fi
if [ -z "$names_file" ]; then
  echo "comment-lint: no names list (set COMMENT_LINT_NAMES to a file outside the repository), so names were not checked; review history was"
fi
echo "comment-lint: ok"
