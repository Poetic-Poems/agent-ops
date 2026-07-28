#!/usr/bin/perl

# td-check.pl <TECH-DEBT.md>
#
# Cross-check a TECH-DEBT.md register for internal consistency:
#   - every open/in-progress Ledger row has exactly one "### <id>" body
#     under Current Items (MISSING BODY / DUPLICATE BODY otherwise);
#   - no resolved/not-debt row still has a body (STALE BODY otherwise);
#   - every body has a Ledger row (NO LEDGER ROW otherwise);
#   - every "| TD... |" Ledger line carries a recognised status and appears
#     only once (BAD ROW / DUPLICATE ROW otherwise).
#
# Prints a one-line summary, a status tally, and one line per problem.
# Exits 0 when consistent, 1 when problems were found, >1 on usage or I/O
# error — so it can gate CI.
#
# The canonical copy lives in Poetic-Poems/poetic (scripts/td-check.pl);
# other repositories hold byte-identical copies, guarded by their
# td-tooling-drift workflow.

use strict;
use warnings;

my $file = shift or die "usage: td-check.pl <TECH-DEBT.md>\n";
open my $fh, '<', $file or die "$file: $!\n";

my (%body_count, %body_line, %status, %status_line, %row_count, %title);
my (@order, @problems);
my $line = 0;
while (<$fh>) {
  $line++;
  if (/^###\s+(TD\d+)/) {
    $body_count{$1}++;
    $body_line{$1} //= $line;
  }
  if (/^\|\s*(TD\d+)\s*\|/) {
    my $id = $1;
    if (/^\|\s*TD\d+\s*\|\s*(.*?)\s*\|\s*(open|in-progress|resolved|not-debt)\s*\|/) {
      my ($row_title, $row_status) = ($1, $2);
      if ($row_count{$id}++) {
        push @problems, "DUPLICATE ROW  $id  ledger:$line";
        next;
      }
      $status{$id}      = $row_status;
      $title{$id}       = $row_title;
      $status_line{$id} = $line;
      push @order, $id;
    } else {
      push @problems, "BAD ROW        $id  ledger:$line  (unrecognised status)";
    }
  }
}
close $fh;

for my $id (@order) {
  my $live = $status{$id} eq 'open' || $status{$id} eq 'in-progress';
  my $n    = $body_count{$id} // 0;
  if ($live && $n == 0) {
    push @problems,
      "MISSING BODY   $id  ledger:$status_line{$id} ($status{$id})  $title{$id}";
  }
  if (!$live && $n > 0) {
    push @problems,
      "STALE BODY     $id  body:$body_line{$id} ledger:$status_line{$id} ($status{$id})  $title{$id}";
  }
  if ($n > 1) {
    push @problems,
      "DUPLICATE BODY $id  ${n}x, first at body:$body_line{$id}";
  }
}
for my $id (sort keys %body_count) {
  push @problems, "NO LEDGER ROW  $id  body:$body_line{$id}"
    unless $row_count{$id};
}

printf "%s: %d ledger rows, %d bodies\n",
  $file, scalar(@order), scalar(keys %body_count);
my %tally;
$tally{ $status{$_} }++ for @order;
printf "  status: %s\n", join(', ', map {"$_=$tally{$_}"} sort keys %tally)
  if @order;
if (@problems) { print "  $_\n" for @problems }
else           { print "  consistent\n" }

exit(@problems ? 1 : 0);
