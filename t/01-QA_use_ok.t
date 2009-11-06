#!/usr/bin/perl
# Copyright 2009, Bartłomiej Syguła (natanael@natanael.krakow.pl)
#
# This is free software. It is licensed, and can be distributed under the same terms as Perl itself.
#
# For more, see by website: http://natanael.krakow.pl
use strict; use warnings;

# DEBUG on
use FindBin qw( $Bin );
use lib $Bin .'/../lib';
# DEBUG off

use Test::More;
use Test::Perl::Critic;

my @perl_files = Test::Perl::Critic::all_perl_files($Bin .q{/../lib/});

plan tests => scalar @perl_files;

foreach my $file (@perl_files) {
    require_ok($file);
}

