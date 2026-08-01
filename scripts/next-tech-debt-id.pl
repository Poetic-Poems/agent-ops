#!/usr/bin/perl

# next-tech-debt-id.pl [--ref REF] [YYMMDD]
#
# Print the next free tech-debt ID for the given date, or today's date if
# none is given.
#
# IDs are TD-<ORG><repo>-<YYMMDD><NN>, where <ORG><repo> is this
# repository's scope code, declared as `scope:` in TECH-DEBT.md's
# frontmatter.  <NN> runs 01-99 then a0-a9 .. z9, never 00 — an encoding
# chosen so plain alphanumeric order equals allocation order.  The next NN
# is computed from the tech-debt/ item filenames for the date (a register
# that has not yet filed its first item has no directory, and simply starts
# at 01); past z9 the script dies, since a repository filing 360 items in
# one day has bigger problems.
#
# With --ref, the register is read from that git ref (e.g. --ref origin/main,
# after a fetch) instead of the working tree, so the allocation reflects the
# shared repository state rather than a possibly stale local checkout. Note
# this still cannot see IDs allocated on unmerged claim branches — check open
# pull requests and td/* branches before relying on the result.
#
# The canonical copy lives in Poetic-Poems/poetic; other repositories hold
# byte-identical copies, guarded by their td-tooling-drift workflow.

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

# Run git in the repo root; return an arrayref of output lines, or undef if
# the command failed.
sub git_lines {
  my @cmd = @_;
  open my $fh, '-|', 'git', '-C', $repo_root, @cmd
    or die "Cannot run git: $!";
  my @lines = <$fh>;
  close $fh;
  return $? == 0 ? \@lines : undef;
}

# Read a repo-relative path from the working tree, or from --ref when given.
sub read_lines {
  my $path = shift;
  if (defined $ref) {
    my $lines = git_lines('show', "$ref:$path");
    defined $lines
      or die "Cannot read $path at ref '$ref' (git show failed)\n";
    return @$lines;
  }
  open my $fh, '<', "$repo_root/$path"
    or die "Cannot open $repo_root/$path for reading: $!";
  my @lines = <$fh>;
  close $fh;
  return @lines;
}

# With --ref, an unresolvable ref is its own loud failure — never mistaken
# for a repository that simply keeps no register.
if (defined $ref) {
  defined git_lines('rev-parse', '--verify', '--quiet', "$ref^{commit}")
    or die "Cannot resolve ref '$ref'\n";
}

sub policy_scope {
  my @policy = eval { read_lines('TECH-DEBT.md') };
  return unless @policy and $policy[0] =~ /^---\s*$/;
  for my $i (1 .. $#policy) {
    last if $policy[$i] =~ /^---\s*$/;
    return $1 if $policy[$i] =~ /^scope:[ \t]*(\S+)\s*$/;
  }
  return;
}

# The NN sequence: 01-99, then a0-a9 .. z9.  ASCII digits sort before
# lowercase letters, so string comparison finds the maximum and alphanumeric
# listings stay in allocation order.
sub next_nn {
  my $max = shift;
  return '01' unless defined $max;
  if ($max =~ /^\d\d$/) {
    return $max < 99 ? sprintf('%02d', $max + 1) : 'a0';
  }
  my ($letter, $digit) = $max =~ /^([a-z])(\d)$/
    or die "Unrecognised NN '$max'\n";
  return $letter . ($digit + 1) if $digit < 9;
  $letter ne 'z'
    or die "NN overflow: $date has used its last ID (z9) — something has "
         . "gone seriously wrong\n";
  return chr(ord($letter) + 1) . '0';
}

my $scope = policy_scope();
defined $scope
  or die "TECH-DEBT.md declares no scope: in its frontmatter\n";
$scope =~ /^[A-Z0-9]{2}[a-z0-9]{4}$/
  or die "Declared scope '$scope' is not <ORG><repo> "
       . "([A-Z0-9]{2}[a-z0-9]{4})\n";

# A register whose directory does not exist yet is simply empty.
my @names;
if (defined $ref) {
  my $listing = git_lines('ls-tree', '--name-only', "$ref:tech-debt");
  @names = defined $listing ? (map { chomp; $_ } @$listing) : ();
} elsif (opendir my $dh, "$repo_root/tech-debt") {
  @names = readdir $dh;
  closedir $dh;
}

my $max;
for my $name (@names) {
  $name =~ /^TD-[A-Z0-9]{2}[a-z0-9]{4}-(\d{6})([0-9a-z]\d)\.md$/ or next;
  next unless $1 eq $date;
  $max = $2 if !defined $max or $2 gt $max;
}
print 'TD-', $scope, '-', $date, next_nn($max), "\n";
