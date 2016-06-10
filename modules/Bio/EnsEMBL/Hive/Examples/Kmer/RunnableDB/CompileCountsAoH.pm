=pod 

=head1 NAME

    Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::CompileCountsAoH

=head1 SYNOPSIS

    Please refer to Bio::EnsEMBL::Hive::Examples::Kmer::PipeConfig::KmerPipelineAoH_conf pipeline configuration file
    to understand how this particular example pipeline is configured and run.

=head1 DESCRIPTION

     Kmer::RunnableDB::CompileCounts is the last runnable in the kmer counting pipleine (using an array of hashes Accumulator).
     This runnable fetches kmer counts that the previous jobs stored in the hash Accumulator, and combines them to determine
     the overall kmer counts from the sequences in the original input file.

=head1 LICENSE

    Copyright [1999-2016] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

    Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

         http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software distributed under the License
    is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and limitations under the License.

=head1 CONTACT

    Please subscribe to the Hive mailing list:  http://listserver.ebi.ac.uk/mailman/listinfo/ehive-users  to discuss Hive-related questions or to be notified of our updates

=cut


package Bio::EnsEMBL::Hive::Examples::Kmer::RunnableDB::CompileCountsAoH;

use strict;
use warnings;

use base ('Bio::EnsEMBL::Hive::Process');


=head2 param_defaults

    Description : Implements param_defaults() interface method of Bio::EnsEMBL::Hive::Process that defines module defaults for parameters.

=cut

sub param_defaults {
}


=head2 fetch_input

    Description : Implements fetch_input() interface method of Bio::EnsEMBL::Hive::Process that is used to read in parameters and load data.
    In this runnable, fetch_input is left empty. It fetches data from a hive Accumulator, so there are no extra database
    connections to open, nor files to check. It's more sensible to fetch data from the Accumulator in run, where it's needed
    rather than to fetch it here, then pass it along in another parameter. 

=cut

sub fetch_input {

}

=head2 run

    Description : Implements run() interface method of Bio::EnsEMBL::Hive::Process that is used to perform the main bulk of the job (minus input and output).

    In this method, we fetch kmer counts produced by previous jobs and stored in an Accumulator. We sum up the
    number of times each kmer is found over all the chunks, and store the sums in a param. Storing the results
    in a param makes them available to other methods in this runnable -- specifically write_output.

    This method expects counts to be stored in the accumulator as an array of hashes. The counts themselves are stored in a hash; the key
    being the kmer sequence, and the value being the count (e.g. {'ACGT' => 5, 'CCGG' => 3, ...}). Each element of the array is a hashref
    pointing to one of these kmer => count hashes generated by a CountKmers job run previously in this pipeline.   

=cut

sub run {
    my $self = shift @_;

    # Create a hash where we can add up counts for each kmer from each previous CountKmers job to determine overall total counts.
    my %sum_of_counts;

    # Accessing the Accumulator by it's name ('all_counts'), as a param.
    # We get an arrayref back.
    my $all_counts = $self->param('all_counts');

    # Loop through all the results from each individual CountKmers job.
    foreach my $count_kmers_result (@{$all_counts}) {

      # for each CountKmers result, retrieve the count for each particular kmer, and add to our total.
      foreach my $kmer (keys %{$count_kmers_result}) {
	  $sum_of_counts{$kmer} += $count_kmers_result->{$kmer};
      }
    }

    # Finally, store our total counts for each kmer in a param called 'sum_of_counts', making them available to other methods
    $self->param('sum_of_counts', \%sum_of_counts);
}

=head2 write_output

    Description : Implements write_output() interface method of Bio::EnsEMBL::Hive::Process that is used to deal with job's output after the execution.

    Here, we flow out two values:
    * kmer  -- the kmer being counted
    * count -- count of that kmer across the entire original input

=cut

sub write_output {
  my $self = shift(@_);

  my $sum_of_counts = $self->param('sum_of_counts');

  foreach my $kmer (keys(%{$sum_of_counts})) {
    $self->dataflow_output_id({
			       'kmer' => $kmer,
			       'count' => $sum_of_counts->{$kmer}
			      }, 4);
  }
}

1;
