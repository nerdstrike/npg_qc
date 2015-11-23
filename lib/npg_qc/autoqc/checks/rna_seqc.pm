package npg_qc::autoqc::checks::rna_seqc;

use Moose;
use namespace::autoclean;
use English qw( -no_match_vars );
use Carp;
use File::Spec::Functions qw( catdir );
use File::Basename;
use File::Path qw(make_path);
use npg_qc::autoqc::types;
use Readonly;
use Try::Tiny;
use npg_tracking::util::types;

extends qw(npg_qc::autoqc::checks::check
           npg_pipeline::base
);

with qw(npg_tracking::data::reference::find 
        npg_common::roles::software_location
        npg_tracking::data::transcriptome::find
       );

our $VERSION = '0';

Readonly::Scalar our $EXT => q[bam];
Readonly::Scalar my $RNASEQC_JAR_NAME       => q[RNA-SeQC_v1.1.8.jar];
Readonly::Scalar my $RNASEQC_JAR_VERSION    => q[1.1.8];
Readonly::Scalar my $RNASEQC_GTF_TTYPE_COL  => 2;
Readonly::Scalar my $RNASEQC_GTF_DIRECTORY  => q[RNA-SeQC];
Readonly::Scalar my $RNASEQC_OUTDIR         => q[rna_seqc];
Readonly::Scalar my $JAVA_MAX_HEAP_SIZE     => q[4000m];
Readonly::Scalar my $JAVA_GC_TYPE           => q[+UseSerialGC];
Readonly::Scalar my $JAVA_USE_PERF_DATA     => q[-UsePerfData];

has '+file_type' => (default => $EXT,);

has '+aligner' => (default => q[fasta],);

has 'java_max_heap_size'     => (is      => 'ro',
                                 isa     => 'Str',
                                 default => $JAVA_MAX_HEAP_SIZE,);

has 'java_gc_type'           => (is      => 'ro',
                                 isa     => 'Str',
                                 default => $JAVA_GC_TYPE,);

has 'java_use_perf_data'     => (is      => 'ro',
                                 isa     => 'Str',
                                 default => $JAVA_USE_PERF_DATA,);

has 'java_jar_path'          => (is      => 'ro',
                                 isa     => 'NpgCommonResolvedPathJarFile',
                                 coerce  => 1,
                                 default => $RNASEQC_JAR_NAME,);

has 'transcript_type' => (is      => 'ro',
                          isa     => 'Int',
                          default => $RNASEQC_GTF_TTYPE_COL,);


has 'alignments_in_bam' => (is         => 'ro',
                            isa        => 'Maybe[Bool]',
                            lazy_build => 1,);

sub _build_alignments_in_bam {
    my ($self) = @_;
    return $self->lims->alignments_in_bam;
}

###############################################################################
# Output path:
#  By default, the pipeline supplies the archive/qc/rna_seqc path under the
#  Latest_Summary directory via the qc_out parameter. This value is used to
#  lazy-build the output path for the RNA-SeQC results within the following
#  path: <qc_out path>/<run_position>/<run_position#tag>. qc_out remains
#  intact so the JSON files end up stored in a non-standard location. This
#  behaviour may change in the future if metrics are to be read and stored.
###############################################################################
has 'qc_out'     => (is         => 'ro',
                     isa        => 'NpgTrackingDirectory',
                     required   => 1,);

has 'rna_seqc_path' => (is         => 'ro',
                       isa        => 'Str',
                       lazy_build => 1,);

sub _build_rna_seqc_path {
    my ($self) = @_;
    my $archive_qc_rna_seqc_path = $self->qc_out;
    my $rp_dir = join q[_], $self->id_run, $self->position;
    my $out_dir = join q[/], $archive_qc_rna_seqc_path, $rp_dir;
    if (defined $self->tag_index) {
        my $rpt_dir = $rp_dir . $self->tag_label;
        $out_dir = join q[/], $archive_qc_rna_seqc_path, $rp_dir, $rpt_dir;
    }
    return $out_dir;
}

has 'input_str' => (is => 'ro',
                    isa        => 'Str',
                    lazy_build => 1,);

sub _build_input_str {
    my ($self) = @_;
    my $sample_id = $self->lims->sample_id;
    my $library_name = $self->lims->library_name // $sample_id;
    my @library_names = split q[ ], $library_name;
    my $input_file = $self->bam_file;
    return qq["$library_names[0]|$input_file|$sample_id"];
}

has 'reference_fasta' => (is => 'ro',
                          isa => 'Maybe[Str]',
                          lazy_build => 1,);

sub _build_reference_fasta {
    my ($self) = @_;
    return $self->refs->[0];
}

has 'bam_file' => (is         => 'ro',
                   isa        => 'Str',
                   lazy_build => 1,);

sub _build_bam_file {
    my $self = shift;
    return $self->input_files->[0];
}

has 'transcriptome' => (is         => 'ro',
                        isa        => 'Maybe[Str]',
                        lazy_build => 1,);

sub _build_transcriptome {
    my $self = shift;
    my $trans_gtf = $self->rnaseqc_gtf_file;
    return $trans_gtf;
}

sub _command {
    my ($self) = @_;
    my $out_dir = $self->rna_seqc_path;
    # check existence of RNA_SeQC's output directory create if it doesn't
    if ( ! -d $out_dir) {
        make_path($out_dir);
    }
    my $single_end_option=q[];
    if(!npg::api::run->new({id_run => $self->id_run})->is_paired_read()){
        $single_end_option=q[-singleEnd];
    }
    my $command = $self->java_cmd. sprintf q[ -Xmx%s -XX:%s -XX:%s -jar %s -s %s -o %s -r %s -t %s -ttype %d %s],
                                           $self->java_max_heap_size,
                                           $self->java_gc_type,
                                           $self->java_use_perf_data,
                                           $self->java_jar_path,
                                           $self->input_str,
                                           $out_dir,
                                           $self->reference_fasta,
                                           $self->transcriptome,
                                           $self->transcript_type,
                                           $single_end_option;
    return $command;
}

has 'config_file_loc' => (is         => 'ro',
                          isa        => 'Str',
                          lazy_build => 1,);

override 'can_run' => sub {
    my $self = shift;
    my $l = $self->lims;
    my $can_run = 1;
    my @comments;
    if(! $self->alignments_in_bam) {
        push @comments, q[Alignments_in_bam is false];
        $can_run = 0;
    }
    if ((! $l->library_type || $l->library_type !~ /(?:cD|R)NA/sxm) && $l->library_type ne q[Pre-quality controlled]) {
        push @comments, join q[ ], q[Not RNA library type: ], $l->library_type;
        $can_run = 0;
    }
    if((! $l->reference_genome) or (not $l->reference_genome =~ /Homo_sapiens|Mus_musculus/smx)){
        push @comments, q[Not human or mouse (only human and mouse transcriptomes available for now)];
        $can_run = 0;
    }
    if(! $self->transcriptome_index_name()){
        push @comments, q[Not transcriptome set so not a splice junction alignment (e.g. Tophat)];
        $can_run = 0;
    }
    if (! $can_run) {
        my $can_run_message = join q[, ], @comments;
        $self->result->add_comment($can_run_message);
        carp qq[Skipping RNA-SeQC check because: $can_run_message];
    }
    return $can_run;
};

override 'execute' => sub {
    my ($self) = @_;
    if (super() == 0) {
    	return 1;
    }
    if ($self->messages->count) {
        $self->result->add_comment(join q[ ], $self->messages->messages);
    }
    my $can_run = $self->can_run();
    if (!$can_run) {
    	return 1;
    }
    $self->result->set_info('Jar', qq[RNA-SeqQC $RNASEQC_JAR_NAME]);
    $self->result->set_info('Jar_version', $RNASEQC_JAR_VERSION);
    my $command = $self->_command();
    $self->result->set_info('Command', $command);
    print qq[Ready to run RNA-SeQC with command:\n$command\n];
    if (system $command) {
        carp "Failed to execute $command";
    }
    #TODO: Call to _parse_metrics(<metrics.tsv file handler>)
    #my $results = $self->_parse_metrics($fh);
    #$self->result->rnaseqc_metrics_path($self->output_dir);
    return 1;
};

__PACKAGE__->meta->make_immutable();

1;

__END__


=head1 NAME

npg_qc::autoqc::checks::rna_seqc - a QC check that runs RNA-SeQC software over an RNA-Seq sample 

=head1 SYNOPSIS

=head1 DESCRIPTION


=head1 SUBROUTINES/METHODS

=head2 new

    Moose-based.

=head2 alignments_in_bam

=head2 java_max_heap_size

=head2 rnaseqc_jar_path

=head2 rnaseqc_command

=head1 DIAGNOSTICS

    None.

=head1 CONFIGURATION AND ENVIRONMENT

=head1 INCOMPATIBILITIES

    None known.

=head1 BUGS AND LIMITATIONS

=head1 DEPENDENCIES

=over

=item Moose

=item namespace::autoclean

=item English

=item Carp

=item File::Spec

=item File::Basename

=item npg_qc::autoqc::types

=item npg::api::run
 
=item Readonly

=item Try::Tiny

=item npg_tracking::data::reference::find

=item npg_common::roles::software_location

=item npg_tracking::data::transcriptome::find

=back

=head1 AUTHOR

Ruben E Bautista-Garcia<lt>rb11@sanger.ac.ukE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2012 GRL, by Ruben Bautista

This file is part of NPG.

NPG is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
