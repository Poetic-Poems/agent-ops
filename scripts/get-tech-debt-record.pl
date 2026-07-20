#!/usr/bin/perl

# get-tech-debt-record.pl ID_SEGMENT
#
# Find tech-debt records for which ID_SEGMENT matches the end of the record's
# ID.  E.g., all of the below will match the ID "TD26070801".
#     get-tech-debt-record.pl 1
#     get-tech-debt-record.pl 801
#     get-tech-debt-record.pl 070801
#     get-tech-debt-record.pl TD26070801
#
# The matched records are printed as a YAML map having these keys:
# - id
# - title
# - body
# - start_line_number
# - end_line_number
#
# The exit code is (number of records matched) - 1.  This means the script only
# succeeds if exactly one record is matched.

use strict;
use warnings;

my $id_segment = shift;
defined $id_segment or die "Please supply an ID segment";
$id_segment =~ /^(?:T?D)?\d+$/ or die "Invalid ID segment '$id_segment'";
my $repo_root = do {
  local $_ = `git rev-parse --show-toplevel`;
  chomp;
  $_ = '.' unless length;
  $_
};
my $fname = "$repo_root/TECH-DEBT.md";
open IN, '<', $fname or die "Cannot open $fname for reading: $!";
my ($previous, @records);
while (my $line = <IN>) {
  next unless defined $previous;
  $previous =~ /^### (TD\d{8}) (.*)/ or next;
  my ($id, $title, $body, $start_line_number) = ($1, $2, '', $. - 1);
  $id =~ /$id_segment$/ or next;
  $title =~ s/'/''/g;
  while ($line = <IN>) {
    last if $line =~ /^### TD\d{8}/ or $line =~ /^## /;
    $body .= '  '.$line;
  }
  push @records, {
    id                => $id,
    title             => $title,
    body              => $body,
    start_line_number => $start_line_number,
    end_line_number   => $. - (defined $line and ($line =~ /^### TD\d{8}/ or $line =~ /^## /))
  };
} continue {
  $previous = $line;
}
close IN;

foreach my $record (@records) {
  print "id:    $record->{id}\n";
  print "title: '$record->{title}'\n";
  print qq{body:  |\n$record->{body}};
  print "start_line_number: $record->{start_line_number}\n";
  print "end_line_number:   $record->{end_line_number}\n\n";
}
exit @records - 1;

