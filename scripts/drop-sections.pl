#!/usr/bin/perl

# drop-sections.pl <TECH-DEBT.md> <id>...
#
# Remove "### <id> ..." sections (the heading through the line before the
# next "###"/"##" heading) from a TECH-DEBT.md — the mechanical half of
# resolving a register item, or of repairing STALE BODY drift that
# td-check.pl reports. Refuses to touch anything outside the Current Items
# section and refuses if an ID has no heading at all; if an ID's heading
# appears more than once (register drift), every occurrence is dropped and
# a note is printed so the duplication stays visible.
#
# The Ledger is never modified: flipping the row's Status is the caller's
# job, per the register's own conventions.
#
# The canonical copy lives in Poetic-Poems/poetic (scripts/drop-sections.pl);
# other repositories hold byte-identical copies, guarded by their
# td-tooling-drift workflow.

use strict;
use warnings;

my $file = shift or die "usage: drop-sections.pl <TECH-DEBT.md> <id>...\n";
my @ids  = @ARGV or die "no ids given\n";

open my $fh, '<', $file or die "$file: $!\n";
my @lines = <$fh>;
close $fh;

my ($current_items, $ledger);
for my $i (0 .. $#lines) {
  $current_items = $i if $lines[$i] =~ /^## Current Items/;
  $ledger        = $i if $lines[$i] =~ /^## Ledger/ && !defined $ledger;
}
die "no Current Items heading\n" unless defined $current_items;
die "no Ledger heading\n"        unless defined $ledger;

my %drop;
for my $id (@ids) {
  my @hits = grep { $lines[$_] =~ /^###\s+\Q$id\E(\s|$)/ } 0 .. $#lines;
  die "$id: no heading found\n" unless @hits;
  warn "$id: NOTE - " . scalar(@hits) . " headings, dropping all\n" if @hits > 1;
  for my $start (@hits) {
    die "$id: heading at line @{[$start + 1]} is outside Current Items\n"
      if $start < $current_items || $start > $ledger;

    my $end = $start + 1;
    $end++ while $end <= $#lines && $lines[$end] !~ /^#{2,3}\s/;
    $drop{$_} = 1 for $start .. $end - 1;
    printf "%s: dropping lines %d-%d\n", $id, $start + 1, $end;
  }
}

my @kept = map { $lines[$_] } grep { !$drop{$_} } 0 .. $#lines;
open my $out, '>', $file or die "$file: $!\n";
print {$out} @kept;
close $out;
printf "%s: %d lines -> %d lines\n", $file, scalar(@lines), scalar(@kept);
