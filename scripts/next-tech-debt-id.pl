#!/usr/bin/perl

# next-tech-debt-id.pl [YYMMDD]
#
# Print the next free TECH-DEBT.md ID (TD<YYMMDD><NN>) for the given date,
# or today's date if none is given. Scans the whole file for any "TD"
# followed by 8 digits — covering both the Ledger table and any live
# "## TD########" entry headers — so the result stays correct even if a
# resolved entry's Ledger row is all that's left.

use strict;
use warnings;

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
open IN, '<', $fname or die "Cannot open $fname for reading: $!";

my $max_nn = 0;
while (my $line = <IN>) {
  while ($line =~ /\bTD(\d{6})(\d{2})\b/g) {
    next unless $1 eq $date;
    my $nn = $2 + 0;
    $max_nn = $nn if $nn > $max_nn;
  }
}
close IN;

printf "TD%s%02d\n", $date, $max_nn + 1;
