// project: s~(packages:\n)~$1  Other:\n    path: Other\n~; s~(        products: \[[^\]]*\]\n)~$1      - package: Other\n~
// expect: which this check cannot read
// A second local package, whose targets the check doesn't describe.
