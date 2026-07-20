#!/usr/bin/perl

# next-tech-debt-id.pl [--ref REF] [YYMMDD]
#
# Print the next free TECH-DEBT.md ID (TD<YYMMDD><NN>) for the given date,
# or today's date if none is given. Scans the whole file for any "TD"
# followed by 8 digits — covering both the Ledger table and any live
# "### TD########" entry headers — so the result stays correct even if a
# resolved entry's Ledger row is all that's left.
#
# With --ref, TECH-DEBT.md is read from that git ref (e.g. --ref origin/main,
# after a fetch) instead of the working tree, so the allocation reflects the
# shared repository state rather than a possibly stale local checkout. Note
# this still cannot see IDs allocated on unmerged claim branches — check open
# pull requests and td/* branches before relying on the result.

use strict;
use warnings;

my $ref;
while (@ARGV and $ARGV[0] =~ /^--/) {
  my $opt = shift;
  if ($opt eq '--ref') {
    $ref = shift;
    defined $ref and $ref !~ /^-/ or die "--ref requires a git ref";
  } else {
    die "Unknown option '$opt'";
  }
}
my $date = shift;
if (defined $date) {
  $date =~ /^\d{6}$/ or die "Invalid date '$date' (expected YYMMDD)\n";
} else {
  my @t = localtime;
  $date = sprintf '%02d%02d%02d', $t[5] % 100, $t[4] + 1, $t[3];
}

my $repo_root = do {
  local $_ = `git rev-parse --show-toplevel`;
  chomp;
  $_ = '.' unless length;
  $_
};
my $fname = "$repo_root/TECH-DEBT.md";
if (defined $ref) {
  open IN, '-|', 'git', '-C', $repo_root, 'show', "$ref:TECH-DEBT.md"
    or die "Cannot run git show: $!";
} else {
  open IN, '<', $fname or die "Cannot open $fname for reading: $!";
}

my $max_nn = 0;
while (my $line = <IN>) {
  while ($line =~ /\bTD(\d{6})(\d{2})\b/g) {
    next unless $1 eq $date;
    my $nn = $2 + 0;
    $max_nn = $nn if $nn > $max_nn;
  }
}
close IN;
defined $ref and $? != 0
  and die "Cannot read TECH-DEBT.md at ref '$ref' (git show failed)\n";

printf "TD%s%02d\n", $date, $max_nn + 1;
