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
# The names are never in the repository, in CI or anywhere else, in plain
# text. What is committed is Config/comment-lint-names.sha256: a line
# "salt: " and 32 hex digits, then for each name the SHA-256, in hex, of
# the salt followed by the name in lower case, the two words of a name of
# two joined by one space. Lines starting with # are comments. The lint
# splits each comment into words (letters, digits and apostrophes, in
# lower case, a trailing 's dropped) and hashes each word, and each word
# with the next, the same way. A match gives the file and line, never the
# name or its hash. A name of more than two words can't be listed.
#
# The plain list lives only in Config/comment-lint-names.local.txt, which
# git ignores: one name per line, blank lines and lines starting with #
# skipped. --hash-names rebuilds the hash file from it, keeping the salt
# when there is one. While the local list is there, the lint fails when
# the hash file has fallen behind it.
#
# Usage: scripts/comment-lint.sh [--hashes file] [path...]
#          (default: the code folders, and the committed hash file)
#        scripts/comment-lint.sh --hash-names
#        scripts/comment-lint.sh --self-test
# The self-test makes up names and a salt of its own, so it never needs the
# real ones.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
committed="$here/../Config/comment-lint-names.sha256"
local_names="$here/../Config/comment-lint-names.local.txt"
hashes="$committed"
if [ "${1:-}" = "--hashes" ]; then
  if [ "$#" -lt 2 ]; then
    echo "comment-lint: --hashes needs a file"
    exit 1
  fi
  hashes="$2"
  shift 2
fi

# Shared by the scan and --hash-names, so a name is hashed the same way
# on both sides.
shared='
  use strict; use warnings; use Digest::SHA ();
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
  sub digest {
    my ($salt, $key) = @_;
    my $bytes = "$salt$key";
    utf8::encode($bytes);
    return Digest::SHA::sha256_hex($bytes);
  }
  # The salt and the set of hashes, or why the file can not be used.
  sub read_hashes {
    my ($file) = @_;
    open(my $fh, "<", $file) or return (undef, undef, "can\x27t read the hashed names in $file");
    my ($salt, %set);
    my $n = 0;
    while (my $line = <$fh>) {
      $n++;
      chomp $line;
      next if $line =~ /^#/;
      if (!defined $salt && $line =~ /^salt: ([0-9a-f]{32})$/) { $salt = $1 }
      elsif ($line =~ /^[0-9a-f]{64}$/) { $set{$line} = 1 }
      else { return (undef, undef, "line $n of $file is not the salt, a hash or a # comment") }
    }
    return (undef, undef, "$file has no salt line") unless defined $salt;
    return ($salt, \%set, "");
  }
  # The names in a plain list, each as its words joined by one space.
  sub read_names {
    my ($file) = @_;
    open(my $fh, "<", $file) or return (undef, "can\x27t read $file");
    my @names;
    my $n = 0;
    while (my $line = <$fh>) {
      $n++;
      next if $line =~ /^\s*(#|$)/;
      my @words = words_of($line);
      next unless @words;
      return (undef, "line $n of $file has more than two words, and the lint matches one or two") if @words > 2;
      push @names, join(" ", @words);
    }
    return (\@names, "");
  }
'

# Reads file names on stdin, one per line, and prints every comment that
# matches: file:line:text for review history, and for a name only
# file:line, so the log never holds the name. Exits 1 on a match, 2 when a
# file can't be read, 3 when the hashed names can't be used.
scan() {
  perl -e "$shared" -e '
    my ($hashes, $names) = @ARGV;
    my ($salt, $set, $broken) = read_hashes($hashes);
    if ($broken) { print "comment-lint: $broken\n"; exit 3 }
    if (!%$set) { print "comment-lint: $hashes holds no names\n"; exit 3 }
    if ($names ne "") {
      my ($list, $why) = read_names($names);
      if (!$list) { print "comment-lint: $why\n"; exit 3 }
      my %listed = map { digest($salt, $_) => 1 } @$list;
      if (join(",", sort keys %listed) ne join(",", sort keys %$set)) {
        print "comment-lint: the hashed names are behind Config/comment-lint-names.local.txt;"
          . " run scripts/comment-lint.sh --hash-names\n";
        exit 3;
      }
    }
    my $history = qr/fix(?:ed)?\s+round|(?<![\w])(?:item|round)\s+[0-9]+/i;
    # A string in double quotes, escapes and all. Never a comment.
    my $quoted = qr/"(?:[^"\\]|\\.)*"/;
    my $found = 0;
    while (my $file = <STDIN>) {
      chomp $file;
      next if $file eq "";
      my $kind = $file =~ /\.swift$/ ? "swift" : $file =~ /\.txt$/ ? "text" : "hash";
      open(my $fh, "<", $file) or do { print "comment-lint: can'"'"'t read $file\n"; exit 2 };
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
        my @words = words_of($comment);
        my @keys = (@words, map { "$words[$_] $words[$_ + 1]" } 0 .. $#words - 1);
        if (grep { $set->{digest($salt, $_)} } @keys) { print "$file:$n: a name from the list\n"; $found = 1 }
        elsif ($comment =~ $history) { print "$file:$n:$line\n"; $found = 1 }
      }
      close $fh;
    }
    exit $found;
  ' "$hashes" "$1"
}

# Rebuilds the committed hash file from the local list, keeping its salt.
# Says only where it wrote, never what.
hash_names() {
  perl -e "$shared" -e '
    my ($names, $hashes) = @ARGV;
    my ($salt, undef, $broken) = -e $hashes ? read_hashes($hashes) : (undef, undef, "");
    if ($broken) { print "comment-lint: $broken; mend it, or remove it for a new salt\n"; exit 1 }
    if (!defined $salt) {
      open(my $random, "<", "/dev/urandom") or die "comment-lint: no /dev/urandom\n";
      read($random, my $raw, 16) == 16 or die "comment-lint: too few random bytes\n";
      $salt = unpack("H*", $raw);
    }
    my ($list, $why) = read_names($names);
    if (!$list) { print "comment-lint: $why\n"; exit 1 }
    if (!@$list) { print "comment-lint: $names holds no names\n"; exit 1 }
    my %seen;
    my @lines = sort grep { !$seen{$_}++ } map { digest($salt, $_) } @$list;
    open(my $out, ">", "$hashes.tmp") or die "comment-lint: can\x27t write $hashes.tmp\n";
    print $out "# The names the comment lint blocks, never in plain text: each line is\n",
      "# the SHA-256 of the salt and a name in lower case, two words joined by\n",
      "# one space. Rebuild with scripts/comment-lint.sh --hash-names.\n",
      "salt: $salt\n", map { "$_\n" } @lines;
    close $out or die "comment-lint: can\x27t write $hashes.tmp\n";
    rename("$hashes.tmp", $hashes) or die "comment-lint: can\x27t write $hashes\n";
    print "comment-lint: hashed the local list into $hashes\n";
  ' "$local_names" "$committed"
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
  # Made-up names under a made-up salt, hashed by shasum rather than the
  # lint's own code, so a lint that stops hashing as it says misses them.
  salt="5e1f7e57c0ffee00d15ea5e0ba5eba11"
  sha() { printf '%s%s' "$1" "$2" | shasum -a 256 | cut -d' ' -f1; }
  {
    echo "# Made up for the self-test."
    echo "salt: $salt"
    sha "$salt" "ada byron"
    sha "$salt" "quillon"
  } > "$dir/names.sha256"
  printf '/// Ada Byron decided this.\n' > "$dir/bad/name.swift"
  printf '/// thanks to ada byron\n' > "$dir/bad/lower.swift"
  printf '/// QUILLON decided this.\n' > "$dir/bad/upper.swift"
  printf "// Quillon's call\n" > "$dir/bad/possessive.swift"
  printf '// Quillon\342\200\231s call\n' > "$dir/bad/curly.swift"
  printf '// asked by Ada   Byron\n' > "$dir/bad/spaces.swift"
  printf '// asked by Ada\tByron\n' > "$dir/bad/tab.swift"
  printf '/* for ADA BYRON\047S sake */\n' > "$dir/bad/twopossessive.swift"
  printf '# from Ada Byron\n' > "$dir/bad/name.sh"
  printf '# a note for quillon\ntest: aTest\n' > "$dir/bad/name.txt"
  # Fine: words that only look alike, and the same words outside a comment.
  printf '/// Rounds to 4 places, and lists items 1 to 3.\nlet rounded = 4\n' > "$dir/good/words.swift"
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
    if sh "$0" --hashes "$dir/names.sha256" "$bad" >/dev/null 2>&1; then
      echo "comment-lint self-test: missed $(basename "$bad")"
      failed=1
    fi
  done
  if ! sh "$0" --hashes "$dir/names.sha256" "$dir/good" >/dev/null 2>&1; then
    echo "comment-lint self-test: flagged a fine comment:"
    sh "$0" --hashes "$dir/names.sha256" "$dir/good" || true
    failed=1
  fi
  # A match says where, never the name.
  if sh "$0" --hashes "$dir/names.sha256" "$dir/bad/name.swift" 2>&1 | grep -qi 'byron'; then
    echo "comment-lint self-test: printed the name it found"
    failed=1
  fi
  # A hash file that can't be read, has no salt, holds a line that is
  # neither salt, hash nor comment, or holds no names is an error.
  grep -v '^salt: ' "$dir/names.sha256" > "$dir/nosalt.sha256"
  { cat "$dir/names.sha256"; echo "quillon"; } > "$dir/stray.sha256"
  { cat "$dir/names.sha256"; echo; } > "$dir/blank.sha256"
  { echo "salt: $salt"; } > "$dir/empty.sha256"
  for broken in nowhere nosalt stray blank empty; do
    if sh "$0" --hashes "$dir/$broken.sha256" "$dir/good" >/dev/null 2>&1; then
      echo "comment-lint self-test: ran with a broken hash file ($broken)"
      failed=1
    fi
  done
  # The committed hash file reads: one salt, then hashes and comments.
  if [ "$(grep -c '^salt: [0-9a-f]\{32\}$' "$committed" || true)" -ne 1 ] \
    || grep -v -e '^salt: [0-9a-f]\{32\}$' -e '^[0-9a-f]\{64\}$' -e '^#' "$committed" >/dev/null \
    || ! sh "$0" "$dir/good" >/dev/null 2>&1; then
    echo "comment-lint self-test: Config/comment-lint-names.sha256 doesn't read as one salt and hashes"
    failed=1
  fi
  # --hash-names, in a copy of the lint, hashes a made-up local list as
  # shasum would, keeps the salt, and the lint then fails once the local
  # list moves on without it.
  mkdir -p "$dir/repo/scripts" "$dir/repo/Config"
  cp "$0" "$dir/repo/scripts/comment-lint.sh"
  copy="$dir/repo/scripts/comment-lint.sh"
  made="$dir/repo/Config/comment-lint-names.sha256"
  printf '# Made up.\n\nAda  Byron\nQuillon\n' > "$dir/repo/Config/comment-lint-names.local.txt"
  sh "$copy" --hash-names >/dev/null 2>&1 || true
  kept="$(sed -n 's/^salt: \([0-9a-f]\{32\}\)$/\1/p' "$made" 2>/dev/null || true)"
  want="$(if [ -n "$kept" ]; then sha "$kept" "ada byron"; sha "$kept" "quillon"; fi | sort)"
  if [ -z "$kept" ] || [ "$(grep -v -e '^#' -e '^salt: ' "$made")" != "$want" ]; then
    echo "comment-lint self-test: --hash-names didn't hash the list with a salt"
    failed=1
  fi
  sh "$copy" --hash-names >/dev/null 2>&1 || true
  if [ -z "$kept" ] || ! grep -qx "salt: $kept" "$made"; then
    echo "comment-lint self-test: --hash-names made a new salt over the old one"
    failed=1
  fi
  if ! sh "$copy" "$dir/good/near.swift" >/dev/null 2>&1; then
    echo "comment-lint self-test: failed with the hash file in step with the local list"
    failed=1
  fi
  printf 'Zeno Quark\n' >> "$dir/repo/Config/comment-lint-names.local.txt"
  if sh "$copy" "$dir/good/near.swift" >/dev/null 2>&1; then
    echo "comment-lint self-test: passed with the hash file behind the local list"
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then exit 1; fi
  echo "comment-lint self-test: ok"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi
if [ "${1:-}" = "--hash-names" ]; then
  if [ ! -r "$local_names" ]; then
    echo "comment-lint: no local list to hash; put the names in Config/comment-lint-names.local.txt"
    exit 1
  fi
  hash_names
  exit 0
fi

[ "$#" -gt 0 ] || set -- Packages/PebbleKit/Sources Packages/PebbleKit/Tests App AppUITests scripts project.yml Makefile

for path in "$@"; do
  if [ ! -e "$path" ]; then
    echo "comment-lint: can't find $path"
    exit 1
  fi
done

# The local list is held against the committed hash file only, never
# against one passed in with --hashes.
check_names=""
if [ "$hashes" = "$committed" ] && [ -r "$local_names" ]; then
  check_names="$local_names"
fi

status=0
hits="$(find "$@" -type f \( -name '*.swift' -o -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name '*.txt' \
  -o -name Makefile \) ! -path '*/.build/*' ! -name 'comment-lint.sh' ! -name 'comment-lint-names*.txt' | sort \
  | scan "$check_names")" || status=$?
if [ "$status" -eq 1 ]; then
  echo "comment-lint: say what the code protects, not the review it came from or who asked:"
  printf '%s\n' "$hits"
  exit 1
elif [ "$status" -eq 3 ]; then
  printf '%s\n' "$hits"
  echo "comment-lint: the hashed names can't be used, so nothing was checked"
  exit 1
elif [ "$status" -ne 0 ]; then
  printf '%s\n' "$hits"
  echo "comment-lint: couldn't read every file"
  exit 1
fi
echo "comment-lint: ok"
