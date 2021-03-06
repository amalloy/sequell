#!/usr/bin/perl
use strict;
use warnings;
use lib 'src';
use Helper qw/:DEFAULT :skills :races/;
use JSON qw//;
use Data::Dumper;

help("Looks up aptitudes for specified race/skill combination.");

my %apts;

# helper functions
sub read_apts {
  my $crawl = shift;
  my $apt_json = qx/$crawl -playable-json/;
  die "Cannot read apts" if $?;
  my $apt = JSON::decode_json($apt_json);
  my %apts;
  for my $sp (@{$apt->{species}}) {
    my $spname = lc($sp->{name});
    if (!$spname) {
      die "No normalized name for $$sp{name}\n";
    }
    my $spapt = $sp->{apts};
    for my $sk (keys %$spapt) {
      $apts{$spname}{lc $sk} = $spapt->{$sk};
    }
    my $spmod = $sp->{modifiers};
    for my $mod (keys %$spmod) {
      next if $mod eq 'stealth';
      my $key = $mod eq 'xp' ? 'experience' : $mod;
      $apts{$spname}{lc $key} = $spmod->{$mod};
    }
  }
  %apts
}

sub is_best_apt { # {{{
    my ($skill, $apt) = @_;
    for (@races) {
        return 0 if ($apts{$_}{$skill} || 0) > $apt;
    }
    return 1;
} # }}}
sub is_worst_apt { # {{{
    my ($skill, $apt) = @_;
    for (@races) {
        next if ($apts{$_}{$skill} || 0) == -99;
        return 0 if $apt > ($apts{$_}{$skill} || 0);
    }
    return 1;
} # }}}
sub format_apt { # {{{
    my ($skill, $apt, $who) = @_;
    if (!defined($apt) || $apt == -99) {
        return 'N/A';
    }
    return $apt . (is_best_apt($skill, $apt) ? "!" :
                   is_worst_apt($skill, $apt) ? "*" : "");
} # }}}
sub check_long_option { # {{{
    my $word = shift;
    $word =~ /-?(.*?)=(.*)/;
    my ($option, $val) = ($1, $2);
    return unless defined $option && defined $val;
    $val = lc $val;

    if ((substr $option, 0, 2) eq 'so') {
        return ('sort', $val);
    }
    elsif ((substr $option, 0, 1) eq 's') {
        return ('skill', normalize_skill($val));
    }
    elsif ((substr $option, 0, 1) eq 'r') {
        return ('race', normalize_race($val));
    }
    elsif ((substr $option, 0, 1) eq 'c') {
        return ('color', $val) if is_valid_drac_color $val;
        error "Invalid color: $val";
    }
    else {
        return;
    }
} # }}}
sub print_single_apt { # {{{
  my ($race, $skill) = @_;
    print short_race($race),
          " (", code_skill($skill), ")=",
          format_apt($skill, $apts{$race}{$skill}, $race), "\n";
} # }}}
sub print_race_apt { # {{{
    my ($race, $sort) = @_;
    my %race_apts = map { $_ => $apts{$race}{$_} } @skills;
    my @keys = @skills;
    $sort ||= '';
    if ($sort eq 'apt') {
        @keys = sort { $race_apts{$b} <=> $race_apts{$a} } @skills;
    }
    elsif ($sort eq 'alpha') {
        @keys = sort @skills;
    }
    my @out;
    for (@keys) {
        push @out, short_skill($_) . ': ' . format_apt($_, $race_apts{$_}, $race);
    }
    print short_race($race), ": ", join(', ', @out), "\n";
} # }}}
sub print_skill_apt { # {{{
    my ($skill, $sort) = @_;
    die "No skill name?" unless $skill;
    my %skill_apts = map { $_ => $apts{$_}{$skill} } @races;
    my @keys = sort { $skill_apts{$b} <=> $skill_apts{$a} } @races;
    $sort ||= 'apt';
    if (!$sort) {
        @keys = @races;
    }
    elsif ($sort eq 'alpha') {
        @keys = sort { lc(short_race($a)) cmp lc(short_race($b)) } @races;
    }
    my @out;
    for (@keys) {
        my $draconian = $_ =~ /draconian/ && $_ ne 'draconian';
        next if $draconian && $skill_apts{$_} == $skill_apts{'draconian'};
        push @out, short_race($_) . ': ' . format_apt($skill, $skill_apts{$_}, $draconian);
    }
    print short_skill($skill), ": ", join(', ', @out), "\n";
} # }}}

# get the aptitudes out of the source file
%apts = read_apts "$source_dir/source/crawl.build";
# get the request
my @words = split ' ', strip_cmdline $ARGV[2];
my @rest;

# loop over the words, checking for things we understand
my %opts;
while (@words) {
    my ($test, $option);

    ($option, $test) = check_long_option $words[0];
    if (defined $test) {
        error "$option already defined with $opts{$option}, but I got $test"
            if exists $opts{$option};
        $opts{$option} = $test;
        shift @words;
        next;
    }

    $test = normalize_race join ' ', @words;
    if (defined $test) {
        error "race already defined with $opts{race}, but I got $test"
            if exists $opts{race};
        $opts{race} = $test;
        @words = @rest;
        @rest = ();
        next;
    }

    $test = normalize_skill join ' ', @words;
    if ($test) {
        error "skill already defined with $opts{skill}, but I got $test"
            if exists $opts{skill};
        $opts{skill} = $test;
        @words = @rest;
        @rest = ();
        next;
    }

    unshift @rest, pop @words;
    if (@words == 0) {
        error "Could not understand \"$rest[0]\"";
    }
}

# check for validity of the color option
if (exists $opts{color}) {
    if (!defined $opts{race} || $opts{race} ne 'base draconian') {
        error "The color option is only valid for draconians";
    }
    $opts{race} = "$opts{color} draconian";
}

# print the result
if (exists $opts{race} && exists $opts{skill}) {
    print_single_apt $opts{race}, $opts{skill}, $opts{sort};
}
elsif (exists $opts{race}) {
    print_race_apt $opts{race}, $opts{sort};
}
elsif (exists $opts{skill}) {
    print_skill_apt $opts{skill}, $opts{sort};
}
else {
    error "You must provide at least a race or a skill";
}
