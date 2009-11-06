# Copyright 2009, Bartłomiej Syguła (natanael@natanael.krakow.pl)
#
# This is free software. It is licensed, and can be distributed under the same terms as Perl itself.
#
# For more, see by website: http://natanael.krakow.pl

package Devel::CoverReport;

use strict;
use warnings;

our $VERSION = 0.01;

use Devel::CoverReport::DB 0.01;
use Devel::CoverReport::Feedback 0.01;

use Carp::Assert::More qw( assert_defined assert_hashref assert_listref );
use Digest::MD5 qw( md5_hex );
use English qw( -no_match_vars );
use File::Slurp qw( read_file );
use Params::Validate qw( :all );
use Storable;
use YAML::Syck qw( DumpFile LoadFile );

=head1 NAME

Devel::CoverReport - Advanced Perl code coverage report generator

=head1 SYNOPSIS

To get coverage report, from existing I<cover_db> database, use:

  cover_report

=head1 DESCRIPTION

This module provides advanced reports based on Devel::Cover database.

=cut

# Size of arrays, for array-based criterions.
my %_ASIZE= (
    branch    => 2,
    condition => 3,
);

=head1 WARNING

Consider this module to be an early ALPHA. It does the job for me, so it's here.

This is my first CPAN module, so I expect that some things may be a bit rough around edges.

The plan is, to fix both those issues, and remove this warning in next immediate release.

=head1 API

=over

=item new

Constructur for C<Devel::CoverReport>.

=cut

sub new { # {{{
    my $class = shift;
    my %P = @_;
    validate(
        @_,
        {
            verbose => { type=>SCALAR },
            quiet   => { type=>SCALAR },
            summary => { type=>SCALAR },

            cover_db  => { type=>SCALAR },
            formatter => { type=>SCALAR },
            output    => { type=>SCALAR },
            criterion => { type=>HASHREF },
            report    => { type=>HASHREF },

            exclude     => { type=>ARRAYREF },
            exclude_dir => { type=>ARRAYREF },
            exclude_re  => { type=>ARRAYREF },
            include     => { type=>ARRAYREF },
            include_dir => { type=>ARRAYREF },
            include_re  => { type=>ARRAYREF },
            mention     => { type=>ARRAYREF },
            mention_dir => { type=>ARRAYREF },
            mention_re  => { type=>ARRAYREF },

            jobs => { type=>SCALAR, optional=>1 },
        }
    );

    my $formatter_class = 'Devel::CoverReport::Formatter::' . $P{'formatter'};

    my $formatter_module = $formatter_class .q{.pm};
    $formatter_module =~ s{::}{/}sg;

#    warn "$formatter_class / $formatter_module";

    require $formatter_module;

    my $self = {
        cover_db     => $P{'cover_db'},
        cover_db_dir => q{},

        db => Devel::CoverReport::DB->new( cover_db => $P{'cover_db'} ),

        feedback => Devel::CoverReport::Feedback->new( quiet => $P{'quiet'}, verbose => $P{'verbose'} ),

        formatter => $formatter_class->new( basedir => $P{'output'}, ),

        'criterion-enabled' => $P{'criterion'},
        'report-enabled'    => $P{'report'},
        
        'criterion-order' => [],

        exclude => {
            by_glob => _glob_to_re($P{'exclude'}),
            by_dir  => _dir_to_re($P{'exclude_dir'}),
            by_re   => _str_to_re($P{'exclude_re'}),
        },

        include => {
            by_glob => _glob_to_re($P{'include'}),
            by_dir  => _dir_to_re($P{'include_dir'}),
            by_re   => _str_to_re($P{'include_re'}),
        },

        mention => {
            by_glob => _glob_to_re($P{'mention'}),
            by_dir  => _dir_to_re($P{'mention_dir'}),
            by_re   => _str_to_re($P{'mention_re'}),
        },

        jobs => undef,

        summary => {
            files => {},
            total => {}
        }
    };

    $self->{'cover_db_dir'} = $self->{'cover_db'};
    $self->{'cover_db_dir'} =~ s{/+[^/]+/?$}{/}s;

    # fixme! ensure, that objects have been created!
    
    if ($P{'jobs'} > 1) {
        my %jobs = (
            max_count => int $P{'jobs'},

            # Fixme: this should be auto-detected!
            spool_dir => q{/dev/shm/},

            pool => {},
        );

        $self->{'jobs'} = \%jobs;
    }

    bless $self, $class;

    # Prepare order of criterions, for tables.
    foreach my $criterion (qw( statement subroutine pod branch condition time )) {
        if ($self->{'criterion-enabled'}->{$criterion}) {
            push @{ $self->{'criterion-order'} }, $criterion;
        }
    }

    return $self;
} # }}}

# Handy methods, that tell if we want to do some aspect of the report, or not.

sub _do_statement { # {{{
    my ( $self ) = @_;
    if ($self->{'criterion-enabled'}->{'statement'}) { return 1; }
    return;
} # }}}
sub _do_branch { # {{{
    my ( $self ) = @_;
    if ($self->{'criterion-enabled'}->{'branch'}) { return 1; }
    return;
} # }}}
sub _do_condition { # {{{
    my ( $self ) = @_;
    if ($self->{'criterion-enabled'}->{'condition'}) { return 1; }
    return;
} # }}}
sub _do_subroutine { # {{{
    my ( $self ) = @_;
    if ($self->{'criterion-enabled'}->{'subroutine'}) { return 1; }
    return;
} # }}}
sub _do_pod { # {{{
    my ( $self ) = @_;
    if ($self->{'criterion-enabled'}->{'pod'}) { return 1; }
    return;
} # }}}
sub _do_time { # {{{
    my ( $self ) = @_;
    if ($self->{'criterion-enabled'}->{'time'}) { return 1; }
    return;
} # }}}

sub _do_coverage_report { # {{{
    my ( $self ) = @_;
    if ($self->{'report-enabled'}->{'coverage'}) { return 1; }
    return;
} # }}}
sub _do_runs_report { # {{{
    my ( $self ) = @_;
    if ($self->{'report-enabled'}->{'runs'}) { return 1; }
    return;
} # }}}
sub _do_run_details_report { # {{{
    my ( $self ) = @_;
    if ($self->{'report-enabled'}->{'run-details'}) { return 1; }
    return;
} # }}}

=item make_report

Make the report, as it was specified during object construction.

Most probably, this is the only method, that most users will have to call, if they want to use this module directly.

The rest will either run L<prove_cover> (it's still the recomended way) or hack deeper - if, for some reason, You just need parts of this module.

=cut
sub make_report { # {{{
    my ( $self ) = @_;

    $self->{'feedback'}->info("Scaning cover_db");

    my %digest_to_run = $self->{'db'}->get_digest_to_run($self->{'feedback'});

    $self->{'feedback'}->info("Generating reports.");

    if ($self->{'jobs'}) {
        $self->_make_in_paralel(\%digest_to_run);
    }
    else {
        $self->_make_in_sequence(\%digest_to_run);
    }

    $self->{'feedback'}->info("Writing summary...");

    my %total_summary_row = (
        'file' => { v=>'Total coverage' },
        'runs' => undef,
    );

    foreach my $criterion (qw( statement subroutine pod branch condition time )) {
        if ($self->{'criterion-enabled'}->{$criterion}) {
            my $coverage = 0;

            if ($self->{'summary'}->{'total'}->{$criterion}->{'count_coverable'}) {
                $coverage = 100 * $self->{'summary'}->{'total'}->{$criterion}->{'count_covered'} / $self->{'summary'}->{'total'}->{$criterion}->{'count_coverable'};
            }

            $total_summary_row{$criterion} = {
                class => c_class($coverage),
                v     => $coverage,
            };
        }
    }

    my $summary_report = $self->make_summary_report(
        \%total_summary_row,
    );

    $self->{'feedback'}->note("Report: ". $summary_report);

    $self->{'formatter'}->finalize();
    
    return 0;
} # }}}


sub _make_in_paralel { # {{{
    my ($self, $digest_to_run) = @_;

    my @digests = $self->{'db'}->digests();

    # Bootstrap
    my $jobs_running = 0;
    while ($jobs_running < $self->{'jobs'}->{'max_count'} and scalar @digests > 0) {
        my $digest = shift @digests;
        
        if ($self->_job_fork($digest, $digest_to_run->{$digest})) {
            $jobs_running++;
        }
    }

    # Stedy, as she goes...
    while (scalar @digests > 0) {
        if ($self->_job_wait()) {
            $jobs_running--;
        }

        my $digest = shift @digests;

        if ($self->_job_fork($digest, $digest_to_run->{$digest})) {
            $jobs_running++;
        }
    }

    # Harvest remaining childs.
    while ($self->_job_wait()) {
        $jobs_running--;
    }

    return;
} # }}}

sub _job_fork { # {{{
    my ($self, $digest, $digest_to_runs) = @_;

    my $pid = fork;
    if ($pid) {
        # Happy parent :)
        $self->{'jobs'}->{'pool'}->{$pid} = $digest;

        return $pid;
    }
    elsif (defined $pid) {
        # Happy child :)

        # Turn on output buffer, we do not want to print when not asked for....
        $self->{'feedback'}->enable_buffer();

        my $structure_data = $self->{'db'}->get_structure_data($digest);

        $self->{'child_report'} = {
            file           => $structure_data->{'file'},
            pid            => $PID,
            classification => 'ERROR',
            feedback       => undef,

            item_summary  => undef,
            total_summary => undef,
        };

        $self->{'feedback'}->at_file($structure_data->{'file'});

        my $file_classification = $self->classify_file($structure_data->{'file'});

        if ($file_classification eq 'EXCLUDE') {
            $self->{'child_report'}->{'clasification'} = $file_classification;
            
            $self->{'feedback'}->warning_at_file("File excluded.");

            $self->_job_done();
        }

        my $new_classification = $self->validate_digest($structure_data);
        if ($new_classification) {
            $self->{'child_report'}->{'clasification'} = $new_classification;

            $self->_job_done();
        }

        my $ok = $self->analyse_digest($digest_to_runs, $digest, $structure_data);

        # Pass summaries to the report, so parent can generate it's index properly.
        $self->{'child_report'}->{'item_summary'}  = $self->{'summary'}->{'files'}->{$digest};
        $self->{'child_report'}->{'total_summary'} = $self->{'summary'}->{'total'};

        return $self->_job_done();
    }

    # Child failed to start!

    return;
} # }}}

sub _job_done { # {{{
    my ($self) = @_;

    $self->{'child_report'}->{'feedback'} = $self->{'feedback'}->dump_buffer();

    DumpFile($self->{'jobs'}->{'spool_dir'} . $PID . q{-cover_report-CR.yml}, $self->{'child_report'});

    # Childs exit, not return...
    return exit 0;
} # }}}

sub _job_wait { # {{{
    my ($self) = @_;

    my $pid = wait;

    if ($pid < 1) {
        return;
    }

    my $digest = delete $self->{'jobs'}->{'pool'}->{$pid};

    my $report_file_name = $self->{'jobs'}->{'spool_dir'} . $pid . q{-cover_report-CR.yml};

    my $child_report = LoadFile($report_file_name);

    # Print child's buffered output.
    $self->{'feedback'}->pass_buffer( $child_report->{'feedback'} );

    # Integrate child's item's summary into our data structure.
    if ($child_report->{'item_summary'}) {
        $self->{'summary'}->{'files'}->{$digest} = $child_report->{'item_summary'};
    }

    # Integrate child's portion of total summary into our data structure.
    if ($child_report->{'total_summary'}) {
        foreach my $criterion (qw( statement subroutine pod branch condition time )) {
            if ($child_report->{'total_summary'}->{$criterion}) {
                $self->{'summary'}->{'total'}->{$criterion}->{'count_coverable'} += $child_report->{'total_summary'}->{$criterion}->{'count_coverable'};
                $self->{'summary'}->{'total'}->{$criterion}->{'count_covered'}   += $child_report->{'total_summary'}->{$criterion}->{'count_covered'};
            }
        }
    }

    # Clean after the child as, well, it's DEAD, so will not clean after itself ;)
    unlink $report_file_name;

    return $pid;
} # }}}

sub _make_in_sequence { # {{{
    my ($self, $digest_to_run) = @_;

    foreach my $digest ( $self->{'db'}->digests() ) {
        my $structure_data = $self->{'db'}->get_structure_data($digest);

        $self->{'feedback'}->at_file($structure_data->{'file'});

        my $file_classification = $self->classify_file($structure_data->{'file'});

        if ($file_classification eq 'EXCLUDE') {
            $self->{'feedback'}->warning_at_file("File excluded.");
            next;
        }

        my $new_classification = $self->validate_digest($structure_data);
        if ($new_classification) {
            # Files, that can not be analysed should be displayed in the report, with proper description.
            # TODO!
            next;
        }

        my $ok = $self->analyse_digest($digest_to_run->{$digest}, $digest, $structure_data);
    }

    $self->{'feedback'}->file_off();

    return;
} # }}}

=item validate_digest

Check if there are some issues, that would not allow a digest to be edded to the report.
In case such issues exist, digest has to be re-classified, and it's analise abandoned.

Parameters: (ARRAY)
 $self
 $structure_data : digest's structure data.

Returns:
 $new_classification : string (like: MISSING, CHANGED) or undef (if no issues ware detected).
=cut
sub validate_digest { # {{{
    my ($self, $structure_data) = @_;

    my $actual_path = $self->_actual_file_path($structure_data->{'file'});

    if (not $actual_path) {
        $self->{'feedback'}->error_at_file("File not reachable!");

        return 'MISSING';
    }

    if ($self->{'db'}->make_file_digest($actual_path) ne $structure_data->{'digest'}) {
        # Check if file was modified since it was covered, as coverage report for changed files will not be reliable!
        $self->{'feedback'}->warning_at_file("File has changed.");

        return 'CHANGED';
    }

    # No issues detected, it's OK to analize this digest :)
    return;
} # }}}

=item classify_file

Determine, if file (identified by it's path) should be INCLUDE-d, MENTION-ed or EXCLUDE-d.

Parameters: (ARRAY)
 $self
 $file_path

Returns:
 $classification_string - one of the: C<INCLUDE>, C<MENTION>, C<EXCLUDE>.

=cut

sub classify_file { # {{{
    my ( $self, $file_path ) = @_;

    if ($self->_classify_as('exclude', $file_path)) {
        return 'EXCLUDE';
    }

    if ($self->_classify_as('mention', $file_path)) {
        return 'MENTION';
    }

    if ($self->_classify_as('include', $file_path)) {
        return 'INCLUDE';
    }

    # Pesimists are safe, be a pesimist - assume worst:
    return 'EXCLUDE';
} # }}}

=item classify_file

Internal function.

Backend for C<classify_file>, iterate over every possible classification method.

Parameters: (ARRAY)
 $self
 $file_path

Returns:
 $classification_string - one of the: C<INCLUDE>, C<MENTION>, C<EXCLUDE>.

=cut

sub _classify_as { # {{{
    my ( $self, $clasification, $file_path ) = @_;

    foreach my $type (qw( by_glob by_dir by_re )) {
        foreach my $regexp (@{ $self->{$clasification}->{$type} }) {
            if ($file_path =~ $regexp) {
                return 1;
            }
        }
    }

    # None matched.
    return 0;
} # }}}

=item analyse_digest

Prepare detailed reports related to coverage or single module, and return some metadata, used later to make a report-wide summary.

Parameters: (ARRAY)
 $self
 $runs   - array of run IDs, that are related to this file (runs, that cover this file)
 $digest - file's ID, assigned to it by Devel::Cover

Returns: (ARRAY)
 \%summary_metadata,

=cut
sub analyse_digest { # {{{
    my ( $self, $runs, $digest, $structure_data ) = @_;

    # Process runs, that covered this file.
    $self->{'feedback'}->progress_open("Runs");

    my ( $per_run_info, $hits ) = $self->_analyse_runs($structure_data->{'file'}, $runs);

    $self->{'feedback'}->progress_close();

    # Summaries:
    my $item_summary = $self->compute_summary($hits->{'global'});

    # Open reports for this file.
    $self->{'formatter'}->add_report(
        code     => $digest,
        basename => namify_path($structure_data->{'file'}),
        title    => 'Coverage: ' . $structure_data->{'file'},
    );

    if ($self->_do_branch()) {
        $self->make_branch_details(namify_path($structure_data->{'file'}) . q{-branch}, $structure_data, $hits->{'global'}->{'branch'});
    }
    if ($self->_do_condition()) {
        $self->make_condition_details(namify_path($structure_data->{'file'}) . q{-condition}, $structure_data, $hits->{'global'}->{'condition'});
    }
    if ($self->_do_subroutine()) {
        $self->make_subroutine_details(namify_path($structure_data->{'file'}) . q{-subroutine}, $structure_data, $hits->{'global'}->{'subroutine'});
    }

    # Walk trough the source file...
    my @source_lines = read_file($self->_actual_file_path($structure_data->{'file'}));

    if ($self->_do_runs_report()) {
        $self->make_runs_details(
            digest         => $digest,
            structure_data => $structure_data,
            run_hits       => $hits->{'run'},
            per_run_info   => $per_run_info,
            source_lines   => \@source_lines,
            item_summary   => $item_summary
        );
    }

    if ($self->_do_coverage_report()) {
        $self->make_coverage_summary(
            structure_data => $structure_data,
            hits           => $hits->{'global'},
            report_id      => $digest,
            source_lines   => \@source_lines,
            item_summary   => $item_summary
        );
    }

    $self->{'formatter'}->close_report($digest);
    
    my %item_summary_row = (
        'file' => { v => $structure_data->{'file'}, href=>namify_path($structure_data->{'file'}), },
        'runs' => ( scalar @{ $runs } ),
    );

    my %hrefs = (
        'branch'     => namify_path($structure_data->{'file'}) .'-branch',
        'subroutine' => namify_path($structure_data->{'file'}) .'-subroutine',
    );

    foreach my $criterion (qw( statement branch condition subroutine pod time )) {
        if ($self->{'criterion-enabled'}->{$criterion} and defined $item_summary->{$criterion}->{'coverage'}) {
            $item_summary_row{$criterion} = {
                class => c_class($item_summary->{$criterion}->{'coverage'}),
                v     => $item_summary->{$criterion}->{'coverage'}
            };

            if ($hrefs{$criterion}) {
                $item_summary_row{$criterion}->{'href'} = $hrefs{$criterion};
            }

            # Append to total summary as well.
            $self->{'summary'}->{'total'}->{$criterion}->{'count_coverable'} += $item_summary->{$criterion}->{'count_coverable'};
            $self->{'summary'}->{'total'}->{$criterion}->{'count_covered'}   += $item_summary->{$criterion}->{'count_covered'};
        }
    }

    $self->{'summary'}->{'files'}->{$digest} = \%item_summary_row;

    return;
} # }}}

sub _analyse_runs { # {{{
    my ( $self, $file, $runs ) = @_;

    # Per-line 'hits', both global and per-run..
    my %hits = (
        global => $self->_empty_hits_container(),
        run    => {
            # Each run will have it's stats here.
        },
    );

    my %per_run_info;

    foreach my $run (@{ $runs }) {
        my $raw_run_data = $self->{'db'}->get_run_data($run);

        # Extract usefull things.
        my $file_run_data = $raw_run_data->{'runs'}->{$run}->{'count'}->{ $file };

        $per_run_info{$run} = {
            'exec' => $raw_run_data->{'runs'}->{$run}->{'run'},
        };

        # fixme! Delete everything, that we do not need from $raw_run_data!

        # Initialize...
        $hits{'run'}->{$run} = $self->_empty_hits_container();

        # Prepare hits.    
        foreach my $criterion (qw( statement subroutine pod time )) {
            if (not $self->{'criterion-enabled'}->{$criterion}) {
                next;
            }

            my $i = 0;
            foreach my $hits_count (@{ $file_run_data->{$criterion} }) {
                if (defined $hits_count) {
                    $hits{'global'}->{$criterion}->[$i] += $hits_count;

                    $hits{'run'}->{$run}->{$criterion}->[$i] += $hits_count;
                }

                $i++;
            }
        }

        # Prepare branch hits.
        if ($self->_do_branch()) {
            my $i = 0;
            foreach my $hits_pair (@{ $file_run_data->{'branch'} }) {
                if ($hits_pair) {
                    $hits{'global'}->{'branch'}->[$i]->[0] += $hits_pair->[0];
                    $hits{'global'}->{'branch'}->[$i]->[1] += $hits_pair->[1];

                    $hits{'run'}->{$run}->{'branch'}->[$i]->[0] += $hits_pair->[0];
                    $hits{'run'}->{$run}->{'branch'}->[$i]->[1] += $hits_pair->[1];
                }

                $i++;
            }
        }

        # Prepare condition hits.
        if ($self->_do_condition()) {
            my $i = 0;
            foreach my $hits_triple (@{ $file_run_data->{'condition'} }) {
                if ($hits_triple) {
                    $hits{'global'}->{'condition'}->[$i]->[0] += ( $hits_triple->[0] or 0 );
                    $hits{'global'}->{'condition'}->[$i]->[1] += ( $hits_triple->[1] or 0 );
                    $hits{'global'}->{'condition'}->[$i]->[2] += ( $hits_triple->[2] or 0 );

                    $hits{'run'}->{$run}->{'condition'}->[$i]->[0] += ( $hits_triple->[0] or 0 );
                    $hits{'run'}->{$run}->{'condition'}->[$i]->[1] += ( $hits_triple->[1] or 0 );
                    $hits{'run'}->{$run}->{'condition'}->[$i]->[2] += ( $hits_triple->[2] or 0 );
                }

                $i++;
            }
        }

        $self->{'feedback'}->progress_tick();
    }

    return ( \%per_run_info, \%hits );
} # }}}

sub _empty_hits_container { # {{{
    my ( $self ) = @_;

    my %container;
    foreach my $condition (@{ $self->{'criterion-order'} }) {
        $container{$condition} = [];
    }
    return \%container;
} # }}}

=item make_runs_details

Parameters: ($self + HASH)
    digest         - digest of the file, for which to prepare run details report
    structure_data
    run_hits       - per-run part of the %hits hash
    per_run_info
    source_lines   - array ref, containing covereg file's contents - line by line.
    item_summary   - data for the summary row

=cut
sub make_runs_details { # {{{
    my $self = shift;
    my %P = @_;
    validate (
        @_,
        {
            digest         => { type=>SCALAR },
            structure_data => { type=>HASHREF },
            run_hits       => { type=>HASHREF },
            per_run_info   => { type=>HASHREF },
            source_lines   => { type=>ARRAYREF },
            item_summary   => { type=>HASHREF },
        }
    );

    my $summary_table = $self->{'formatter'}->add_table(
        $P{'digest'},
        'CoverBy',
        {
            label   => 'Covered by:',
            headers => {
                'run' => { caption=>'Run',     f=>q{%d},    fs=>q{%d},  class=>'head' },

                'statement'  => { caption=>'St.',   f=>q{%d%%},  fs=>q{%.1f%%} },
                'branch'     => { caption=>'Br.',   f=>q{%d%%},  fs=>q{%.1f%%} },
                'condition'  => { caption=>'Cond.', f=>q{%d%%},  fs=>q{%.1f%%} },
                'subroutine' => { caption=>'Sub.',  f=>q{%d%%},  fs=>q{%.1f%%} },
                'pod'        => { caption=>'POD',   f=>q{%d%%},  fs=>q{%.1f%%} },
                'time'       => { caption=>'Time',  f=>q{%.3fs}, fs=>q{%.3fs} },

                'command' => { caption=>'Command', f=>q{%s},    fs=>q{%s},  class=>'file' },
            },
            headers_order => [ 'run', @{ $self->{'criterion-order'} }, 'command' ],
        }
    );

    my $item_no = 1;
    foreach my $run (sort {$P{'per_run_info'}->{$a}->{'exec'} cmp $P{'per_run_info'}->{$b}->{'exec'}} keys %{ $P{'per_run_info'} }) {
        # Summary for this run...
        my $run_summary = $self->compute_summary($P{'run_hits'}->{$run});

        # Add a row about the run...
        my %row = (
            'run' => $item_no++,

            'command' => {
                v => $P{'per_run_info'}->{$run}->{'exec'},
            },
        );

        foreach my $criterion (@{ $self->{'criterion-order'} }) {
            $row{$criterion} = {
                class => c_class($run_summary->{$criterion}->{'coverage'}),
                v     => $run_summary->{$criterion}->{'coverage'},
            };
        }

        $summary_table->add_row(\%row);

        # If enabled, cenerate per-run stats too.
        if ($self->_do_run_details_report()) {
            my $namified_path = namify_path($P{'structure_data'}->{'file'});

            $self->{'formatter'}->add_report(
                code     => $P{'digest'} .q{-}. $run,
                basename => $namified_path . q{-} . $run,
                title    => 'Coverage: ' . $P{'structure_data'}->{'file'},
            );

            if ($self->_do_branch()) {
                $self->make_branch_details($namified_path . q{-} . $run . q{-branch}, $P{'structure_data'}, $P{'run_hits'}->{$run}->{'branch'});

                $row{'branch'}->{'href'} = $namified_path . q{-} . $run . q{-branch};
            }
            if ($self->_do_condition()) {
                $self->make_condition_details($namified_path . q{-} . $run . q{-condition}, $P{'structure_data'}, $P{'run_hits'}->{$run}->{'condition'});

                $row{'condition'}->{'href'} = $namified_path . q{-} . $run . q{-condition};
            }
            if ($self->_do_subroutine()) {
                $self->make_subroutine_details($namified_path . q{-} . $run . q{-subroutine}, $P{'structure_data'}, $P{'run_hits'}->{$run}->{'subroutine'});

                $row{'subroutine'}->{'href'} = $namified_path . q{-} . $run . q{-subroutine};
            }

            if ($self->_do_coverage_report()) {
                $row{'command'}->{'href'} = $namified_path . q{-} . $run;

                $self->make_coverage_summary(
                    structure_data => $P{'structure_data'},
                    hits           => $P{'run_hits'}->{$run},
                    report_id      => $P{'digest'} . q{-} . $run,
                    source_lines   => $P{'source_lines'},
                    item_summary   => $run_summary,
                );
            }

            $self->{'formatter'}->close_report($P{'digest'} . q{-} . $run);
        }
    }
    
    # Add total-totals as well.
    my %index_summary_row = (
        'run'     => $item_no,
        'command' => 'Total coverage',
    );
    foreach my $criterion (@{ $self->{'criterion-order'} }) {
        $index_summary_row{$criterion} = {
            class => c_class($P{'item_summary'}->{$criterion}->{'coverage'}),
            v     => $P{'item_summary'}->{$criterion}->{'coverage'},
        };
    }
    $summary_table->add_summary(\%index_summary_row);

    return;
} # }}}

=item make_coverage_summary

Make coverage information report for single structure entiry (Perl script or module).

Parameters: ($self + HASH)
  structure_data
  hits
  report_id    - string: 'namified' file path with run ID (if per-run coverages are turned ON)
  source_lines - array ref, containing covereg file's contents - line by line.
  item_summary - data for the summary row

=cut
sub make_coverage_summary { # {{{
    my $self = shift;
    my %P = @_;
    validate(
        @_,
        {
            structure_data => { type=>HASHREF },
            hits           => { type=>HASHREF },
            report_id      => { type=>SCALAR },
            source_lines   => { type=>ARRAYREF },
            item_summary   => { type=>HASHREF },
        }
    );

    # Per-line criterions.
    my %per_line_criterions = $self->_make_per_line_criterions($P{'structure_data'}, $P{'hits'});

    my $coverage_table = $self->{'formatter'}->add_table(
        $P{'report_id'},
        'Coverage',
        {
            label   => 'Overall file coverage:',
            headers => {
                'line' => { caption=>'Line', f=>q{%d}, fs=>q{%d}, class=>'head' },

                'statement'  => { caption=>'St.',   f=>q{%d},    fs=>q{%.1f%%} },
                'branch'     => { caption=>'Br.',   f=>q{%d},    fs=>q{%.1f%%} },
                'condition'  => { caption=>'Cond.', f=>q{%d},    fs=>q{%.1f%%} },
                'subroutine' => { caption=>'Sub.',   f=>q{%d},    fs=>q{%.1f%%} },
                'pod'        => { caption=>'POD',   f=>q{%d},    fs=>q{%.1f%%} },
                'time'       => { caption=>'Time',  f=>q{%.3fs}, fs=>q{%.3fs} },

                'source' => { caption=>'Source code', f=>q{%s}, fs=>q{%s}, class=>'src' },
            },
            headers_order => [qw( line statement branch condition subroutine pod time source )],
        }
    );

    my $hr_ln = 1; # Humar-Readable Line Number
    foreach my $line (@{ $P{'source_lines'} }) {
#        push @report_lines, q{<tr valign=top style="border: 1px solid #cccccc;">};

        my %row = (
            'line' => $hr_ln,

            'statement'  => [],
            'branch'     => [],
            'condition'  => [],
            'subroutine' => [],
            'pod'        => [],
            'time'       => [],

            'source' => $line,
        );

        foreach my $criterion (qw( statement subroutine pod )) {
            if (defined $per_line_criterions{$criterion}->[$hr_ln]) {
                foreach my $count (@{ $per_line_criterions{$criterion}->[$hr_ln] }) {
                    if ($count) {
                        push @{ $row{$criterion} }, { class => 'c4', v => $count };
                    }
                    else {
                        push @{ $row{$criterion} }, { class => 'c0', v => $count };
                    }
                }
            }
        }
        foreach my $criterion (qw( branch condition )) {
            if (defined $per_line_criterions{$criterion}->[$hr_ln]) {
                foreach my $count (@{ $per_line_criterions{$criterion}->[$hr_ln] }) {
                    if ($count == 100) {
                        push @{ $row{$criterion} }, { class => 'c4', v => $count };
                    }
                    elsif ($count) {
                        push @{ $row{$criterion} }, { class => 'c1', v => $count };
                    }
                    else {
                        push @{ $row{$criterion} }, { class => 'c0', v => $count };
                    }
                }
            }
        }
        if (defined $per_line_criterions{'time'}->[$hr_ln]) {
            foreach my $count (@{ $per_line_criterions{'time'}->[$hr_ln] }) {
                push @{ $row{'time'} }, $count;
            }
        }

        foreach my $criterion (qw( subroutine branch condition )) {
            if ($row{$criterion}) {
                foreach my $item (@{ $row{$criterion} }) {
                    $item->{'href'}   = $P{'report_id'} . q{-} . $criterion;
                    $item->{'anchor'} = $hr_ln;
                }
            }
        }

        $coverage_table->add_row(\%row);

        $hr_ln++;
    }
    
    $coverage_table->add_summary(
        {
            'line' => $hr_ln - 1,

            'statement'  => { class=>c_class($P{'item_summary'}->{'statement'}->{'coverage'}),  v=>$P{'item_summary'}->{'statement'}->{'coverage'},  },
            'branch'     => { class=>c_class($P{'item_summary'}->{'branch'}->{'coverage'}),     v=>$P{'item_summary'}->{'branch'}->{'coverage'},     },
            'condition'  => { class=>c_class($P{'item_summary'}->{'condition'}->{'coverage'}),  v=>$P{'item_summary'}->{'condition'}->{'coverage'},  },
            'subroutine' => { class=>c_class($P{'item_summary'}->{'subroutine'}->{'coverage'}), v=>$P{'item_summary'}->{'subroutine'}->{'coverage'}, },
            'pod'        => { class=>c_class($P{'item_summary'}->{'pod'}->{'coverage'}),        v=>$P{'item_summary'}->{'pod'}->{'coverage'},        },
            'time'       => { class=>c_class($P{'item_summary'}->{'time'}->{'coverage'}),       v=>$P{'item_summary'}->{'time'}->{'coverage'},       },

            'src' => 'Total coverage',
        }
    );

    return;
} # }}}

=item _make_per_line_criterions

Internal function.

Distribute criterions from DB into each of the phisical source lines.

Parameters: (ARRAY)
  $self
  $structure_data
  $hits

Returns:
  Hash
=cut
sub _make_per_line_criterions { # {{{
    my ( $self, $structure_data, $hits ) = @_;
    validate_pos(
        @_,
        { type=>OBJECT },
        { type=>HASHREF },
        { type=>HASHREF },
    );

    my %per_line_criterions;

    # Process statement and time criterions.
    foreach my $criterion (qw( statement time )) {
        my $i = 0;

        foreach my $hit_count (@{ $hits->{$criterion} }) {
            my $line_hit = $structure_data->{$criterion}->[$i];

            if(defined $line_hit) {
                push @{ $per_line_criterions{$criterion}->[$line_hit] }, $hit_count;
            }

            $i++;
        }
    }

    # Process subroutine and pod.
    foreach my $criterion (qw( subroutine pod )) {
        my $i = 0;

        foreach my $hit_count (@{ $hits->{$criterion} }) {
            my $line_hit = $structure_data->{$criterion}->[$i];

            if ($line_hit and $line_hit->[0]) {
                # FIXME:
                #   it DOES happen, that structure file has no information related to some function.
                #   I have observed it while running under --jobs, maybe it's some race condition...
                push @{ $per_line_criterions{$criterion}->[ $line_hit->[0] ] }, $hit_count;
            }
            else {
                # Fixme: if we have a hit, in one of the runs, but have no 'structure' information related to it - it's a bug in Devel::Cover!
            }

            $i++;
        }
    }

    # Process branch criterions.
    foreach my $criterion (qw( branch condition )) {
        my $i = 0;
        foreach my $hits_array (@{ $hits->{$criterion} }) {
            my $line_hit = $structure_data->{$criterion}->[$i]->[0];

            assert_defined($line_hit, "Unknown line number? ". $i);

            my $hits_count = 0;
            foreach my $part (@{ $hits_array }) {
                if ($part) {
                    $hits_count++;
                }
            }

            $hits_count = 100 * $hits_count / $_ASIZE{$criterion};

            push @{ $per_line_criterions{$criterion}->[$line_hit] }, int $hits_count;

            $i++;
        }
    }

    return %per_line_criterions;
} # }}}

=item make_branch_details

Make detailed branch coverage report.

Parameters:
  $self
  $basename
  $structure_data
  $hits
=cut
sub make_branch_details { # {{{
    my ($self, $basename, $structure_data, $hits) = @_;

#    if ($structure_data->{'file'} =~ m{L10N}) {
#        use Data::Dumper; warn Dumper $structure_data->{'branch'};
#        use Data::Dumper; warn Dumper $hits;
#    }

    my %lines;
    my $i = 0;
    foreach my $hits_array (@{ $hits }) {
        my $line_no = $structure_data->{'branch'}->[$i]->[0];

        my %line = (
            '_coverage' => 0,

            'c_true'  => q{?},
            'c_false' => q{?},

            'line' => $line_no,
        );

        if ($hits_array->[0]) {
            $line{'_coverage'} += 50;
            $line{'c_true'} = { class=>q{c4}, v=>'T' };
        }
        else {
            $line{'c_true'} = { class=>q{c0}, v=>'T' };
        }

        if ($hits_array->[1]) {
            $line{'_coverage'} += 50;
            $line{'c_false'} = { class=>q{c4}, v=>'F' };
        }
        else {
            $line{'c_false'} = { class=>q{c0}, v=>'F' };
        }

        $lines{$line_no} = \%line;

        $i++;
    }

    $self->{'formatter'}->add_report(
        code     => $basename,
        basename => $basename,
        title    => 'Branch coverage: ' . $structure_data->{'file'},
    );
    my $coverage_table = $self->{'formatter'}->add_table(
        $basename,
        'Coverage',
        {
            label   => 'Branch coverage',
            headers => {
                'line' => { caption=>'Line', f=>q{%d}, fs=>q{%d}, class=>'head' },

                'percent' => { caption=>q{%},    f=>q{%d}, fs=>q{%.1f} },
                'c_true'  => { caption=>'True',  f=>q{%s}, fs=>q{%.1f} },
                'c_false' => { caption=>'False', f=>q{%s}, fs=>q{%.1f} },

                'branch' => { caption=>'Branch', f=>q{%s}, fs=>q{%s}, class=>'src' },
            },
            headers_order => [qw( line percent c_true c_false branch )],
        }
    );
    foreach my $hit (@{ $structure_data->{'branch'} }) {
        my $line_no = $hit->[0];

        my $line = $lines{ $line_no };

        $line->{'percent'} = {
            class => c_class($line->{'_coverage'}),
            v     => $line->{'_coverage'},
        };
        $line->{'branch'} = $hit->[1]->{'text'};
        
#        warn $line->{'_coverage'} .q{ -> }. c_class($line->{'_coverage'});

        $coverage_table->add_row($line);
    }

    $self->{'formatter'}->close_report($basename);

    return;
} # }}}

=item make_subroutine_details

Make detailed subroutine coverage report.

Parameters:
  $self
  $basename
  $structure_data
  $hits
=cut
sub make_subroutine_details { # {{{
    my ($self, $basename, $structure_data, $hits) = @_;

#    if ($structure_data->{'file'} =~ m{L10N}) {
#        use Data::Dumper; warn Dumper $structure_data->{'subroutine'};
#        use Data::Dumper; warn Dumper $hits;
#    }

    my %lines;
    my $i = 0;
    foreach my $hits_count (@{ $hits }) {
        my $line_no = $structure_data->{'subroutine'}->[$i]->[0];

        if ($line_no) {
            my %line = (
                'line'       => $line_no,
                'hits'       => { v=>$hits_count, class=>'c0' },
                'subroutine' => q{?},
            );

            if ($hits_count) {
                $line{'hits'}->{'class'} = 'c4';
            }

            $lines{$line_no} = \%line;
        }
        else {
            # Fixme: if we have a hit, in one of the runs, but have no 'structure' information related to it - it's a bug in Devel::Cover!
        }

        $i++;
    }

    $self->{'formatter'}->add_report(
        code     => $basename,
        basename => $basename,
        title    => 'Subroutine coverage: ' . $structure_data->{'file'},
    );

    my $coverage_table = $self->{'formatter'}->add_table(
        $basename,
        'Coverage',
        {
            label   => 'Subroutine coverage',
            headers => {
                'line'       => { caption=>'Line',       f=>q{%d}, fs=>q{%d}, class=>'head' },
                'hits'       => { caption=>'Hits',       f=>q{%d}, fs=>q{%d} },
                'subroutine' => { caption=>'Subroutine', f=>q{%s}, fs=>q{%s}, class=>'src' },
            },
            headers_order => [qw( line hits subroutine )],
        }
    );

    foreach my $hit (@{ $structure_data->{'subroutine'} }) {
        if ($hit->[0]) {
            my $line_no = $hit->[0];

            my $line = $lines{ $line_no };

            $line->{'subroutine'} = $hit->[1];

            $coverage_table->add_row($line);
        }
        else {
            # Fixme: if we have a hit, in one of the runs, but have no 'structure' information related to it - it's a bug in Devel::Cover!
        }
    }

    $self->{'formatter'}->close_report($basename);

    return;
} # }}}

=item make_condition_details

Make detailed branch coverage report.

Parameters:
  $self
  $basename
  $structure_data
  $hits
=cut
sub make_condition_details { # {{{
    my ($self, $basename, $structure_data, $hits) = @_;

#    if ($structure_data->{'file'} =~ m{L10N}) {
#        use Data::Dumper; warn Dumper $structure_data->{'condition'};
#        use Data::Dumper; warn Dumper $hits;
#    }

    # Fixme! There is probably a bug in this subroutine, due to my poor understanding of those data structures!!.

    my %lines;
    my $i = 0;
    foreach my $hits_count (@{ $hits }) {
        my $line_no = $structure_data->{'condition'}->[$i]->[0];

        my $hits_count = 0;
        my $cover = 0;

        my $code = sprintf q{%s %s %s}, $structure_data->{'condition'}->[$i]->[1]->{'left'}, $structure_data->{'condition'}->[$i]->[1]->{'op'}, $structure_data->{'condition'}->[$i]->[1]->{'right'};

        my %line = (
            'line'  => $line_no,
            'cover' => { v=>$hits_count, class=>c_class($cover) },
            'code'  => $code,
        );

        if ($hits_count) {
            $line{'hits'}->{'class'} = 'c4';
        }

        $lines{$line_no} = \%line;

        $i++;
    }

    $self->{'formatter'}->add_report(
        code     => $basename,
        basename => $basename,
        title    => 'Condition coverage: ' . $structure_data->{'file'},
    );

    my $coverage_table = $self->{'formatter'}->add_table(
        $basename,
        'Coverage',
        {
            label   => 'Condition coverage',
            headers => {
                'line'  => { caption=>'Line',      f=>q{%d}, fs=>q{%d}, class=>'head' },
                'cover' => { caption=>q{%},        f=>q{%d}, fs=>q{%d} },
                'code'  => { caption=>'Condition', f=>q{%s}, fs=>q{%s}, class=>'src' },
            },
            headers_order => [qw( line cover code )],
        }
    );
    foreach my $line (sort {$a->{'line'} <=> $b->{'line'}} values %lines) {
        $coverage_table->add_row($line);
    }

    $self->{'formatter'}->close_report($basename);

    return;
} # }}}

=item make_summary_report

Make file index, with coverage summary for each.

Parameters:
  $self
  $total_summary - total (all files/runs average) summary
=cut
sub make_summary_report { # {{{
    my ( $self, $total_summary ) = @_;

    my $summary_report = $self->{'formatter'}->add_report(
        code     => 'Summary',
        basename => 'cover_report',
        title    => 'Coverage summary'
    );

    my $covered_table = $self->{'formatter'}->add_table(
        'Summary',
        'Files',
        {
            label => 'Covered files:',

            headers => {
                file => { caption => 'File', f=>q{%s}, class => 'file' },

                'statement'  => { caption=>'St.',   f=>q{%d%%}, fs=>q{%.1f%%} },
                'branch'     => { caption=>'Br.',   f=>q{%d%%}, fs=>q{%.1f%%} },
                'condition'  => { caption=>'Cond.', f=>q{%d%%}, fs=>q{%.1f%%} },
                'subroutine' => { caption=>'Sub.',   f=>q{%d%%}, fs=>q{%.1f%%} },
                'pod'        => { caption=>'POD',   f=>q{%d%%}, fs=>q{%.1f%%} },

                'time' => { caption=>'Time',  f=>q{%.3fs}, fs=>q{%.3fs} },

                'runs' => { caption=>'Runs', f=>q{%d}, fs=>q{%d} },
            },
            headers_order => [ 'file', @{ $self->{'criterion-order'} }, 'runs' ],
        }
    );
    
    # Add rows for every single covered file:
    foreach my $file_summary (sort { $a->{'file'}->{'v'} cmp $b->{'file'}->{'v'} } values %{ $self->{'summary'}->{'files'} }) {
        $covered_table->add_row($file_summary);
    }

    # Add total summary as well:
    $covered_table->add_summary($total_summary);

    return $self->{'formatter'}->close_report('Summary');
} # }}}

=item compute_summary

Utility routine, compute summary for each criterion.

=cut

sub compute_summary { # {{{
    my ( $self, $source ) = @_;
    
    assert_hashref($source, "Source must be a hashref.");

    # Start by checking how many non-zeros we have...
    my %summary;
    foreach my $criterion (qw( statement subroutine pod )) {
        if (not $self->{'criterion-enabled'}->{$criterion}) {
            next;
        }

        assert_listref($source->{$criterion}, "Source for criterion $criterion must be an array ref." );

        my $total_hit_counter = 0;

        foreach my $hit_counter (@{ $source->{$criterion} }) {
            if ($hit_counter) {
                $total_hit_counter++;
            }
        }

        # One hash, to rule them all ;)
        $summary{$criterion} = {
            count_coverable => scalar @{ $source->{$criterion} },
            count_covered   => $total_hit_counter,
        };

        # Compute percent values.
        if ($summary{$criterion}->{'count_coverable'}) {
            $summary{$criterion}->{'coverage'} = 100 * $summary{$criterion}->{'count_covered'} / $summary{$criterion}->{'count_coverable'};
        }
        else {
            $summary{$criterion}->{'coverage'} = 0;
        }
    }

    foreach my $criterion (qw( branch condition )) {
        if (not $self->{'criterion-enabled'}->{$criterion}) {
            next;
        }

        # Initialize:
        $summary{$criterion} = {
            count_coverable => $_ASIZE{$criterion} * scalar @{ $source->{$criterion} },
            count_covered   => 0,
        };

        foreach my $list (@{ $source->{$criterion} }) {
            foreach my $hit (@{ $list }) {
                if ($hit) {
                    $summary{$criterion}->{'count_covered'}++;
                }
            }
        }

        if ($summary{$criterion}->{'count_coverable'}) {
            $summary{$criterion}->{'coverage'} = 100 * $summary{$criterion}->{'count_covered'} / $summary{$criterion}->{'count_coverable'};
        }
        else {
            $summary{$criterion}->{'coverage'} = 0;
        }
    }

    return \%summary;
} # }}}

sub _actual_file_path { # {{{
    my ( $self, $path ) = @_;

    if (-f $path) {
        return $path;
    }

    if (-f $self->{'cover_db_dir'} . $path) {
        return $self->{'cover_db_dir'} . $path;
    }

    return;
} # }}}

=item c_class

Compute proper c-class, used for color-coding coverage information:
    c0  : not covered or coverage < 50%
    c1  : coverage >= 50%
    c2  : coverage >= 75%
    c3  : coverage >= 90%
    c4  : covered or coverage = 100%

Static function.

=cut

sub c_class { # {{{
    my ( $percentage ) = @_;

    if ($percentage) {
        if ($percentage == 100) {
            return 'c4';
        }
    
        if ($percentage >= 90) {
            return 'c3';
        }
    
        if ($percentage >= 75) {
            return 'c2';
        }
    
        if ($percentage >= 50) {
            return 'c1';
        }
    }

    return 'c0';
} # }}}

=item namify_path

If image is worth a thousand words, then example should cound as about 750...
Turn something like this:
    /home/natanael/Perl/Foo/Bar/Baz.pm

into this:
    -home-natanael-Perl-Foo-Bar-Baz-pm

Additionally, remove any characters, that could confuse shell.
Effectivelly, the resulting string should be safe for use in shell,
web and by childrens under 3 years old :)

Static function.

=cut
sub namify_path { # {{{
    my ( $path ) = @_;

    $path =~ s{/}{-}sg;
    $path =~ s{\.}{-}sg;
    
    # fixme!

    return $path;
} # }}}

sub _glob_to_re { # {{{
    my ( $list ) = @_;

    my @new_list;
    foreach my $item (@{ $list }) {
        $item =~ s{([^\w\s])}{\\$1}g; # Fixme: check if this REALY works.

        $item =~ s{\*}{[^/]+}sg;
        $item =~ s{\?}{[^/]}sg;

        push @new_list, qr{$item}s;
    }

    return \@new_list;
} # }}}

sub _dir_to_re{ # {{{
    my ( $list ) = @_;

    my @new_list;
    foreach my $item (@{ $list }) {
        $item = quotemeta $item;

        push @new_list, qr{^$item}s;
    }

    return \@new_list;
} # }}}


sub _str_to_re{ # {{{
    my ( $list ) = @_;

    my @new_list;
    foreach my $item (@{ $list }) {
        push @new_list, qr{$item}s;
    }

    return \@new_list;
} # }}}

1;

__END__

=back

=head1 LICENCE

Copyright 2009, Bartłomiej Syguła (natanael@natanael.krakow.pl)

# This is free software. It is licensed, and can be distributed under the same terms as Perl itself.

For more, see by website: http://natanael.krakow.pl

=cut

# vim: fdm=marker

