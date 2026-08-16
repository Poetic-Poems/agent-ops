#!/usr/bin/perl

# td-check.pl [<tech-debt-dir>]
#
# Cross-check a per-item tech-debt register for internal consistency.  With
# no argument, checks ./tech-debt — or, when that directory does not exist
# yet (a register that has not filed its first item), just validates the
# scope declaration in ./TECH-DEBT.md and reports an empty, consistent
# register.
#
# Every entry in the register directory must be one item file — named
# TD-<ORG><repo>-<YYMMDD><NN>.md (NN 01-99 then a0-z9, never 00) — whose
# frontmatter parses and carries id/title/status/filed, with id equal to
# the filename stem and scoped to the `scope:` declared in the frontmatter
# of the TECH-DEBT.md beside the directory, a recognised status, resolution
# fields consistent with that status, a filed date matching the ID's, and,
# while status is open or in-progress, a body containing non-whitespace
# text (resolved/not-debt items are exempt, to grandfather legacy items
# migrated with an empty body).
# Problem labels:
#   BAD NAME, BAD FRONTMATTER, MISSING FIELD, BAD FIELD, BAD STATUS,
#   BAD SCOPE, NO SCOPE, ID MISMATCH, DATE MISMATCH, STALE FIELD,
#   DUPLICATE ID
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

my $target = shift;
if (defined $target and !-d $target) {
  die "td-check.pl checks a per-item register directory; "
    . "'$target' is not one\n";
}

exit check_dir(defined $target ? $target : 'tech-debt');

sub problem_line {
  my ($label, $detail) = @_;
  return sprintf '%-15s%s', $label, $detail;
}

sub check_dir {
  my $dir = shift;
  (my $parent = $dir) =~ s{/?[^/]+/?$}{};
  $parent = '.' unless length $parent;
  my $policy = "$parent/TECH-DEBT.md";

  my (@problems, %status, %seen_id);
  my @order;

  # The register's scope is declared beside it, in the policy document's
  # frontmatter.
  my $scope;
  if (open my $fh, '<', $policy) {
    my @lines = <$fh>;
    close $fh;
    if (@lines and $lines[0] =~ /^---\s*$/) {
      for my $i (1 .. $#lines) {
        last if $lines[$i] =~ /^---\s*$/;
        if ($lines[$i] =~ /^scope:[ \t]*(\S+)\s*$/) { $scope = $1; last }
      }
    }
  }
  push @problems, problem_line('NO SCOPE',
    "$policy missing or lacking a scope: frontmatter declaration")
    unless defined $scope and $scope =~ /^[A-Z0-9]{2}[a-z0-9]{4}$/;

  # A register that has not filed its first item has no directory yet:
  # nothing to check beyond the scope declaration above.
  my @names;
  if (opendir my $dh, $dir) {
    @names = sort grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;
  }

  for my $name (@names) {
    if (-d "$dir/$name"
        or $name !~ /^(TD-([A-Z0-9]{2}[a-z0-9]{4})-(\d{6})([0-9a-z]\d))\.md$/
        or $4 eq '00') {
      push @problems, problem_line('BAD NAME', $name);
      next;
    }
    my ($stem, $name_scope, $date, $nn) = ($1, $2, $3, $4);

    open my $fh, '<', "$dir/$name" or die "$dir/$name: $!\n";
    my @lines = <$fh>;
    close $fh;

    my %meta;
    my $end;
    if (@lines and $lines[0] =~ /^---\s*$/) {
      for my $i (1 .. $#lines) {
        if ($lines[$i] =~ /^---\s*$/) { $end = $i; last }
        $meta{lc $1} = $2
          if $lines[$i] =~ /^([A-Za-z][A-Za-z-]*):[ \t]*(.*?)\s*$/;
      }
    }
    unless (defined $end) {
      push @problems, problem_line('BAD FRONTMATTER', $name);
      next;
    }

    for my $key (qw(id title status filed)) {
      push @problems, problem_line('MISSING FIELD', "$name ($key)")
        unless defined $meta{$key} and length $meta{$key};
    }

    my $id = $meta{id} // '';
    if (length $id and $id ne $stem) {
      push @problems, problem_line('ID MISMATCH', "$name (id: $id)");
    }
    if (length $id) {
      push @problems, problem_line('DUPLICATE ID', "$name (also $seen_id{$id})")
        if $seen_id{$id};
      $seen_id{$id} //= $name;
    }

    if (defined $scope and $name_scope ne $scope) {
      push @problems, problem_line('BAD SCOPE',
        "$name (scope $name_scope, repository declares $scope)");
    }

    my $st = $meta{status};
    my $live = defined $st && ($st eq 'open' || $st eq 'in-progress');
    if (defined $st and length $st) {
      if ($st =~ /^(open|in-progress|resolved|not-debt)$/) {
        $status{$name} = $st;
        push @order, $name;
        if ($live) {
          for my $key (qw(resolved ref)) {
            push @problems, problem_line('STALE FIELD',
              "$name ($key: set on an $st item)")
              if defined $meta{$key} and length $meta{$key};
          }
        } else {
          push @problems, problem_line('MISSING FIELD', "$name (ref)")
            unless defined $meta{ref} and length $meta{ref};
          push @problems, problem_line('MISSING FIELD', "$name (resolved)")
            if $st eq 'resolved'
            and not(defined $meta{resolved} and length $meta{resolved});
        }
      } else {
        push @problems, problem_line('BAD STATUS', "$name ($st)");
      }
    }

    my $filed = $meta{filed};
    if (defined $filed and length $filed) {
      if ($filed =~ /^\d{2}(\d{2})-(\d{2})-(\d{2})$/) {
        push @problems, problem_line('DATE MISMATCH',
          "$name (filed $filed, ID date $date)")
          unless "$1$2$3" eq $date;
      } else {
        push @problems, problem_line('BAD FIELD', "$name (filed: $filed)");
      }
    }

    my $legacy = $meta{'legacy-id'};
    push @problems, problem_line('BAD FIELD', "$name (legacy-id: $legacy)")
      if defined $legacy and length $legacy and $legacy !~ /^TD\d{8}$/;

    if ($live) {
      my $body = join '', @lines[$end + 1 .. $#lines];
      push @problems, problem_line('MISSING FIELD', "$name (body must contain non-whitespace)")
        unless $body =~ /\S/;
    }
  }

  printf "%s: %d items\n", $dir, scalar @order;
  my %tally;
  $tally{ $status{$_} }++ for @order;
  printf "  status: %s\n", join(', ', map {"$_=$tally{$_}"} sort keys %tally)
    if @order;
  if (@problems) { print "  $_\n" for @problems }
  else           { print "  consistent\n" }
  return @problems ? 1 : 0;
}
