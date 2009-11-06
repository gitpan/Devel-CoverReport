#!/usr/bin/perl
# Copyright 2009, Bartłomiej Syguła (natanael@natanael.krakow.pl)
#
# This is free software. It is licensed, and can be distributed under the same terms as Perl itself.
#
# For more, see by website: http://natanael.krakow.pl
use strict; use warnings;

use FindBin qw( $Bin );
use Test::More;

# This test is targetted at the module maintainer.
# Users do not need to run it.
if (not $ENV{'MAINTAIN'} =~ m{Devel::CoverReport}) {
    plan skip_all => 'Add Devel::CoverReport to MAINTAIN env variable.';
}

eval {
    require Test::Perl::Critic;
};
if ($@) {
    plan skip_all => 'Test::Perl::Critic not installed';
}
else {
    import Test::Perl::Critic (
        -severity => 3,
        -exclude  => [
            qw(
                Subroutines::RequireArgUnpacking
                RegularExpressions::RequireExtendedFormatting
            )
        ]
    );

    all_critic_ok( $Bin . q{/../lib} );
}

# vim: fdm=marker

