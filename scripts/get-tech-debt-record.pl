#!/usr/bin/perl

# get-tech-debt-record.pl [--ref REF] ID_SEGMENT
#
# Find tech-debt records for which ID_SEGMENT matches the end of the record's
# ID — or, in the per-item register, the end of its legacy-id.  E.g., all of
# the below match the ID "TD-PPpoet-26070801" (legacy-id "TD26070801"):
#     get-tech-debt-record.pl 1
#     get-tech-debt-record.pl 801
#     get-tech-debt-record.pl poet-26070801
#     get-tech-debt-record.pl TD-PPpoet-26070801
#     get-tech-debt-record.pl TD26070801
#
# The register is read adaptively:
#   - per-item format: one record per file under tech-debt/, YAML frontmatter
#     plus Markdown body — used whenever that directory exists;
#   - legacy format: "### <id> <title>" sections in a single TECH-DEBT.md.
#
# With --ref, the register is read from that git ref (e.g. --ref origin/main,
# after a fetch) instead of the working tree, so resolution reflects the
# shared repository state rather than a possibly stale or wrongly-branched
# local checkout.
#
# The matched records are printed as a YAML map having these keys:
# - id
# - legacy-id  (per-item register only, when the record carries one)
# - title
# - status     (omitted when a legacy register has no Ledger row for the ID)
# - path
# - body
#
# The exit code is (number of records matched) - 1.  This means the script only
# succeeds if exactly one record is matched.
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
my $id_segment = shift;
defined $id_segment or die "Please supply an ID segment";
$id_segment =~ /^(?:T?D)?\d+$/
  or $id_segment =~ /^(?:TD-)?[A-Za-z0-9][A-Za-z0-9-]*\d$/
  or die "Invalid ID segment '$id_segment'";

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
  shift @body while @body and $body[0] =~ /^\s*$/;
  return (\%meta, join '', @body);
}

my $new_format;
if (defined $ref) {
  $new_format =
    defined git_lines('rev-parse', '--verify', '--quiet', "$ref:tech-debt");
} else {
  $new_format = -d "$repo_root/tech-debt";
}

my @records;
if ($new_format) {
  my @names;
  if (defined $ref) {
    my $listing = git_lines('ls-tree', '--name-only', "$ref:tech-debt");
    defined $listing or die "Cannot list tech-debt/ at ref '$ref'\n";
    @names = map { chomp; $_ } @$listing;
  } else {
    opendir my $dh, "$repo_root/tech-debt"
      or die "Cannot open $repo_root/tech-debt: $!";
    @names = readdir $dh;
    closedir $dh;
  }
  for my $name (sort grep { /\.md$/ } @names) {
    my ($meta, $body) = parse_item(read_lines("tech-debt/$name"));
    next unless $meta and defined $meta->{id};
    my $legacy = $meta->{'legacy-id'};
    $meta->{id} =~ /\Q$id_segment\E$/
      or (defined $legacy and $legacy =~ /\Q$id_segment\E$/)
      or next;
    push @records, {
      id     => $meta->{id},
      legacy => $legacy,
      title  => $meta->{title} // '',
      status => $meta->{status},
      path   => "tech-debt/$name",
      body   => $body,
    };
  }
} else {
  my @lines = read_lines('TECH-DEBT.md');
  my %status;
  for (@lines) {
    $status{$1} = $2
      if /^\|\s*(TD\d+)\s*\|.*?\|\s*(open|in-progress|resolved|not-debt)\s*\|/;
  }
  for (my $i = 0; $i <= $#lines; $i++) {
    $lines[$i] =~ /^### (TD\d{8}) (.*)/ or next;
    my ($id, $title) = ($1, $2);
    my $body = '';
    my $j = $i + 1;
    while ($j <= $#lines
        and $lines[$j] !~ /^### TD\d{8}/ and $lines[$j] !~ /^## /) {
      $body .= $lines[$j];
      $j++;
    }
    $i = $j - 1;
    next unless $id =~ /\Q$id_segment\E$/;
    push @records, {
      id     => $id,
      title  => $title,
      status => $status{$id},
      path   => 'TECH-DEBT.md',
      body   => $body,
    };
  }
}

foreach my $record (@records) {
  (my $title = $record->{title}) =~ s/'/''/g;
  my $body = $record->{body};
  $body .= "\n" if length $body and $body !~ /\n$/;
  $body =~ s/^/  /mg;
  print "id:    $record->{id}\n";
  print "legacy-id: $record->{legacy}\n"
    if defined $record->{legacy} and length $record->{legacy};
  print "title: '$title'\n";
  print "status: $record->{status}\n" if defined $record->{status};
  print "path:  $record->{path}\n";
  print qq{body:  |\n$body};
  print "\n";
}
exit @records - 1;
