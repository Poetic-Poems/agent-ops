#!/usr/bin/perl

# reserve-tech-debt-id.pl [YYMMDD]
#
# Atomically reserve the next free tech-debt ID for the given date, or
# today's date if none is given, by pushing a claim branch td/<id> from
# origin/main -- the same race-safe lock the "Claiming an item" workflow
# in TECH-DEBT.md already uses to work an existing item. Prints the
# reserved ID on success; the caller then fetches and checks out that
# branch and files tech-debt/<id>.md on it (see TECH-DEBT.md's "Filing an
# item").
#
# A candidate NN is computed once, from the register committed on
# origin/main (as `next-tech-debt-id.pl --ref origin/main` would report)
# together with any td/* branches already on origin -- so an ID already
# reserved by an unmerged filing or claim is skipped without spending a
# push on it. A push can still be rejected by a race landing between the
# scan and the push; that failure is retried too, incrementing NN each
# time, until one succeeds or the day's NN sequence (01-99, a0-z9; never
# 00 -- see next-tech-debt-id.pl) is exhausted.
#
# Each push is guarded with --force-with-lease=refs/heads/td/<id>: (read
# "the ref must not currently exist") rather than a plain push, because a
# plain push of origin/main to an *existing* td/<id> branch that happens
# to be an ancestor of the new origin/main succeeds as an ordinary
# fast-forward -- silently moving someone else's reservation to a new
# commit. The lease turns that into the rejection it should always have
# been.
#
# The pushed commit is never origin/main's own commit verbatim -- it is a
# throwaway commit on top of origin/main's tree, carrying a nonce in its
# message body. Two racers contending for the same id would otherwise push
# the exact same origin/main commit, and the loser's push would find the ref
# already at the very value it was about to push: a no-op ("Everything
# up-to-date") that git treats as success and --force-with-lease never
# even evaluates, since no update is happening. The nonce guarantees every
# attempt's commit is unique, so a loser's push is always a genuine
# (and thus rejected) conflicting update instead.
#
# That commit stays in the filing branch's history until the pull request is
# squash-merged, so its subject line is written in Conventional Commits form
# ("chore(tech-debt): reserve <id>"): .github/workflows/commit-format.yml
# checks every commit on a pull request, not just the title, and would fail
# an otherwise perfectly good filing over it.
#
# Requires a git remote named `origin`; fetches origin/main itself, so no
# prior `git fetch` is needed (unlike --ref origin/main elsewhere in this
# register's tooling, which reads whatever the caller already fetched).
#
# The canonical copy lives in Poetic-Poems/poetic; other repositories hold
# byte-identical copies, guarded by their td-tooling-drift workflow.

use strict;
use warnings;

my $date = shift;
if (defined $date) {
  $date =~ /^\d{6}$/ or die "Invalid date '$date' (expected YYMMDD)\n";
} else {
  my @t = localtime;
  $date = sprintf '%02d%02d%02d', $t[5] % 100, $t[4] + 1, $t[3];
}
die "Unexpected extra argument '$ARGV[0]'\n" if @ARGV;

my $repo_root = do {
  local $_ = `git rev-parse --show-toplevel`;
  chomp;
  $_ = '.' unless length;
  $_
};

# Run git in the repo root; return an arrayref of stdout lines, or undef if
# the command failed.
sub git_lines {
  my @cmd = @_;
  open my $fh, '-|', 'git', '-C', $repo_root, @cmd
    or die "Cannot run git: $!";
  my @lines = <$fh>;
  close $fh;
  return $? == 0 ? \@lines : undef;
}

# Run a git command with stdout and stderr merged into the returned text
# (via a shell, since Perl's list-form open cannot merge fds on its own);
# every argument is shell-quoted individually, and every argument this
# script ever passes is either the fixed repo_root or a string this script
# itself built and validated (an ID or a ref name), never external input.
# Returns ($ok, $combined_output).
sub git_shell {
  my @cmd = @_;
  my $quoted = join ' ', map { quotemeta } ('git', '-C', $repo_root, @cmd);
  my $output = `$quoted 2>&1`;
  return ($? == 0, $output);
}

my ($fetch_ok, $fetch_output) = git_shell('fetch', 'origin', 'main');
$fetch_ok or die "Cannot fetch origin main:\n$fetch_output";

sub policy_scope {
  my $lines = git_lines('show', 'origin/main:TECH-DEBT.md');
  return unless $lines;
  my @policy = @$lines;
  return unless @policy and $policy[0] =~ /^---\s*$/;
  for my $i (1 .. $#policy) {
    last if $policy[$i] =~ /^---\s*$/;
    return $1 if $policy[$i] =~ /^scope:[ \t]*(\S+)\s*$/;
  }
  return;
}

# The NN sequence: 01-99, then a0-a9 .. z9 -- identical to
# next-tech-debt-id.pl's, kept in step with it deliberately.
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
    or die "NN overflow: $date has used its last ID (z9) -- something has "
         . "gone seriously wrong\n";
  return chr(ord($letter) + 1) . '0';
}

my $scope = policy_scope();
defined $scope
  or die "TECH-DEBT.md (at origin/main) declares no scope: in its frontmatter\n";
$scope =~ /^[A-Z0-9]{2}[a-z0-9]{4}$/
  or die "Declared scope '$scope' is not <ORG><repo> "
       . "([A-Z0-9]{2}[a-z0-9]{4})\n";

# Highest NN already filed in the committed register, for this date.
my $filed_max;
{
  my $listing = git_lines('ls-tree', '--name-only', 'origin/main:tech-debt');
  my @names = $listing ? (map { chomp; $_ } @$listing) : ();
  for my $name (@names) {
    $name =~ /^TD-\Q$scope\E-(\d{6})([0-9a-z]\d)\.md$/ or next;
    next unless $1 eq $date;
    $filed_max = $2 if !defined $filed_max or $2 gt $filed_max;
  }
}

# Highest NN already reserved (filed or claimed, merged or not) via a
# td/<id> branch on origin, for this date.
my $reserved_max;
{
  my $listing = git_lines('ls-remote', 'origin', 'refs/heads/td/*');
  my @refs = $listing ? (map { chomp; $_ } @$listing) : ();
  for my $line (@refs) {
    next unless $line =~ m{refs/heads/td/TD-\Q$scope\E-(\d{6})([0-9a-z]\d)$};
    next unless $1 eq $date;
    $reserved_max = $2 if !defined $reserved_max or $2 gt $reserved_max;
  }
}

my $max;
for my $candidate ($filed_max, $reserved_max) {
  next unless defined $candidate;
  $max = $candidate if !defined $max or $candidate gt $max;
}

my $tree = do {
  my $lines = git_lines('rev-parse', 'origin/main^{tree}');
  $lines and @$lines or die "Cannot resolve origin/main's tree\n";
  chomp(my $t = $lines->[0]);
  $t;
};

my $nn = next_nn($max);
while (1) {
  my $id = "TD-$scope-$date$nn";

  # Each attempt's push must carry a payload no other reservation attempt
  # -- concurrent or past -- could ever push byte-for-byte: a plain push of
  # origin/main's own commit is identical for every racer contending for
  # this id, so a racer that loses the push race still finds the ref
  # already at the exact value it was about to push and gets a silent,
  # successful no-op ("Everything up-to-date") instead of the rejection
  # this whole scheme depends on -- --force-with-lease only guards an
  # actual ref *update*, and a no-op is not one. A nonce'd throwaway commit
  # on top of origin/main's tree sidesteps that: every attempt's commit
  # object differs, so only the first push can ever be a no-op, and every
  # later one is a genuine (and therefore rejected) conflicting update.
  # The subject stays Conventional Commits-shaped because this commit sits
  # in the filing pull request's history, where commit-format.yml sees it.
  my $nonce = join '-', time(), $$, int(rand(1_000_000));
  my $commit_lines = git_lines('commit-tree', $tree, '-p', 'origin/main',
    '-m', "chore(tech-debt): reserve $id\n\nReservation nonce: $nonce");
  $commit_lines and @$commit_lines
    or die "Cannot create a reservation commit for $id\n";
  chomp(my $commit = $commit_lines->[0]);

  my $lease = "refs/heads/td/$id:";
  my ($ok) = git_shell('push', "--force-with-lease=$lease", 'origin',
    "$commit:refs/heads/td/$id");
  if ($ok) {
    print "$id\n";
    exit 0;
  }

  # The push failed. If the ref now exists on origin, another writer won
  # the race for this id -- retry with the next one. Otherwise this is a
  # genuine failure (network, auth, ...) and looping would only mask it.
  my $exists = git_lines('ls-remote', 'origin', "refs/heads/td/$id");
  if ($exists and @$exists) {
    $nn = next_nn($nn);
    next;
  }
  die "git push failed to reserve $id, and refs/heads/td/$id does not "
    . "exist on origin either -- not a collision, giving up\n";
}
