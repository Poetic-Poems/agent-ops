#!/usr/bin/perl

# check-tech-debt-open-rewrites.pl BASE_REF HEAD_REF [DIR]
#
# Flags a pull request that rewrites existing text in an *open* tech-debt
# item's body while leaving its status: untouched. DIR defaults to
# tech-debt.
#
# An open item's body is append-only (see docs/TECH-DEBT-REGISTER.md):
# existing text is immutable while status: stays open, and new text may be
# appended (e.g. a "Referenced from:" note, or a newly-learned detail) --
# only a status: move (claiming, resolving) may accompany a body rewrite.
# The atomic reservation reserve-tech-debt-id.pl provides (see its own
# header) closes the id-allocation half of the collision this register saw
# on 2026-08-08 (agent-ops PR #257), but not the other half: a writer whose
# local clone already contains an item that has since been resolved on the
# far side can still overwrite its body as an ordinary content
# *modification* -- git records that as a change to an existing file, not
# the add/add conflict a same-id *filing* collision produces, so neither
# the deletion/rename guard nor td-check.pl notices. An open item whose
# existing text changed without its status: field moving is exactly that
# failure mode (or, short of a race, a policy breach) -- either way, a
# reviewer should see a red check rather than a silently corrupted
# permanent record. A collision can never look like a strict append: that
# would require the colliding item's body to begin with the victim's
# entire body verbatim.
#
# For each file present (and parseable) at both refs under DIR whose body
# differs by more than a trailing append, and whose status: at BASE_REF is
# "open", and whose status: at HEAD_REF is unchanged from BASE_REF: report
# it as a problem. Prints one line per problem; exits 0 when none are
# found, 1 when problems were found, >1 on usage or I/O error.
#
# The canonical copy lives in Poetic-Poems/poetic; other repositories hold
# byte-identical copies, guarded by their td-tooling-drift workflow.

use strict;
use warnings;

my ($base_ref, $head_ref, $dir) = @ARGV;
defined $base_ref and defined $head_ref
  or die "Usage: check-tech-debt-open-rewrites.pl BASE_REF HEAD_REF [DIR]\n";
$dir = 'tech-debt' unless defined $dir;

my $repo_root = do {
  local $_ = `git rev-parse --show-toplevel`;
  chomp;
  $_ = '.' unless length;
  $_;
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

for my $ref ($base_ref, $head_ref) {
  defined git_lines('rev-parse', '--verify', '--quiet', "$ref^{commit}")
    or die "Cannot resolve ref '$ref'\n";
}

# Split an item file into a frontmatter hash and a body string; returns the
# empty list unless a complete frontmatter block is present.
sub parse_item {
  my @lines = @_;
  @lines and $lines[0] =~ /^---\s*$/ or return;
  my (%meta, $end);
  for my $i (1 .. $#lines) {
    if ($lines[$i] =~ /^---\s*$/) { $end = $i; last }
    $meta{lc $1} = $2 if $lines[$i] =~ /^([A-Za-z][A-Za-z-]*):[ \t]*(.*?)\s*$/;
  }
  defined $end or return;
  my @body = @lines[$end + 1 .. $#lines];
  return (\%meta, join '', @body);
}

sub read_item {
  my ($ref, $path) = @_;
  my $lines = git_lines('show', "$ref:$path");
  return unless $lines;
  return parse_item(@$lines);
}

my $merge_base_lines = git_lines('merge-base', $base_ref, $head_ref);
my $merge_base = do {
  chomp(my $mb = ($merge_base_lines // [])->[0] // '');
  length $mb ? $mb : $base_ref;
};

my $changed = git_lines('diff', '--name-only', '--diff-filter=M',
  "$merge_base...$head_ref", '--', $dir);
my @paths = $changed ? (map { chomp; $_ } @$changed) : ();

my @problems;
for my $path (@paths) {
  my ($base_meta, $base_body) = read_item($merge_base, $path);
  next unless $base_meta;
  my ($head_meta, $head_body) = read_item($head_ref, $path);
  next unless $head_meta;

  next unless ($base_meta->{status} // '') eq 'open';
  next unless ($head_meta->{status} // '') eq 'open';
  next if $base_body eq $head_body;
  next if $base_body =~ /\S/
    and length($head_body) > length($base_body)
    and substr($head_body, 0, length $base_body) eq $base_body;

  push @problems,
    "BODY REWRITE   $path (status: open unchanged, body differs)";
}

if (@problems) {
  print "$_\n" for @problems;
  exit 1;
}
print "no open-item body rewrites\n";
exit 0;
