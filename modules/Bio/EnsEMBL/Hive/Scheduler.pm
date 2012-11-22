=pod 

=head1 NAME

    Bio::EnsEMBL::Hive::Scheduler

=head1 DESCRIPTION

    Scheduler starts with the numbers of required workers for unblocked analyses,
    then goes through several kinds of restrictions (submit_limit, meadow_limits, hive_capacity, etc)
    that act as limiters and may cap the original numbers in several ways.
    The capped numbers are then grouped by meadow_type and rc_name and returned in a two-level hash.

=head1 CONTACT

  Please contact ehive-users@ebi.ac.uk mailing list with questions/suggestions.

=cut


package Bio::EnsEMBL::Hive::Scheduler;

use strict;
use warnings;

use Clone 'clone';

use Bio::EnsEMBL::Hive::Analysis;
use Bio::EnsEMBL::Hive::AnalysisStats;
use Bio::EnsEMBL::Hive::Queen;
use Bio::EnsEMBL::Hive::Valley;
use Bio::EnsEMBL::Hive::Limiter;


sub schedule_workers_resync_if_necessary {
    my ($queen, $valley, $filter_analysis) = @_;

    my $available_worker_slots_by_meadow_type                                       = $valley->get_available_worker_slots_by_meadow_type();

    my $analysis_id2rc_id         = $queen->db->get_AnalysisAdaptor->fetch_HASHED_FROM_analysis_id_TO_resource_class_id();
    my $rc_id2name                = $queen->db->get_ResourceClassAdaptor->fetch_HASHED_FROM_resource_class_id_TO_name();
        # combined mapping:
    my $analysis_id2rc_name       = { map { $_ => $rc_id2name->{ $analysis_id2rc_id->{ $_ }} } keys %$analysis_id2rc_id };

    my ($workers_to_submit_by_meadow_type_rc_name, $total_workers_to_submit)
        = schedule_workers($queen, $valley, $filter_analysis, $available_worker_slots_by_meadow_type, $analysis_id2rc_name);

    unless( $total_workers_to_submit or $queen->get_hive_current_load() or $queen->count_running_workers() ) {
        print "\nScheduler: nothing is running and nothing to do (according to analysis_stats) => executing garbage collection and sync\n" ;

        $queen->check_for_dead_workers($valley, 1);
        $queen->synchronize_hive($filter_analysis);

        ($workers_to_submit_by_meadow_type_rc_name, $total_workers_to_submit)
            = schedule_workers($queen, $valley, $filter_analysis, $available_worker_slots_by_meadow_type, $analysis_id2rc_name);
    }

        # adjustment for pending workers:
    my ($pending_worker_counts_by_meadow_type_rc_name, $total_pending_all_meadows)  = $valley->get_pending_worker_counts_by_meadow_type_rc_name();

    while( my ($this_meadow_type, $partial_workers_to_submit_by_rc_name) = each %$workers_to_submit_by_meadow_type_rc_name) {
        while( my ($this_rc_name, $workers_to_submit_this_group) = each %$partial_workers_to_submit_by_rc_name) {
            if(my $pending_this_group = $pending_worker_counts_by_meadow_type_rc_name->{ $this_meadow_type }{ $this_rc_name }) {

                print "Scheduler was thinking of submitting $workers_to_submit_this_group x $this_meadow_type:$this_rc_name workers when it detected $pending_this_group pending in this group, ";

                if( $workers_to_submit_this_group > $pending_this_group) {
                    $total_workers_to_submit                                                        -= $pending_this_group;
                    $workers_to_submit_by_meadow_type_rc_name->{$this_meadow_type}{$this_rc_name}   -= $pending_this_group; # adjust the hashed value
                    print "so is going to submit only ".$workers_to_submit_by_meadow_type_rc_name->{$this_meadow_type}{$this_rc_name}." extra\n";
                } else {
                    $total_workers_to_submit                                                        -= $workers_to_submit_this_group;
                    delete $workers_to_submit_by_meadow_type_rc_name->{$this_meadow_type}{$this_rc_name};                   # avoid leaving an empty group in the hash
                    print "so is not going to submit any extra\n";
                }
            } else {
                print "Scheduler is going to submit $workers_to_submit_this_group x $this_meadow_type:$this_rc_name workers\n";
            }
        }
    }

    return ($workers_to_submit_by_meadow_type_rc_name, $total_workers_to_submit);
}


sub schedule_workers {
    my ($queen, $valley, $filter_analysis, $available_worker_slots_by_meadow_type, $analysis_id2rc_name) = @_;

    my @suitable_analyses   = $filter_analysis
                                ? ( $filter_analysis->stats )
                                : @{ $queen->db->get_AnalysisStatsAdaptor->fetch_all_by_suitability_rc_id_meadow_type() };

    unless(@suitable_analyses) {
        print "Scheduler could not find any suitable analyses to start with\n";
        return ({}, 0);
    }

        # the pre-pending-adjusted outcome will be stored here:
    my %workers_to_submit_by_meadow_type_rc_name    = ();
    my $total_workers_to_submit                     = 0;

    my $default_meadow_type                         = $valley->get_default_meadow()->type;

    my $available_submit_limit                      = $valley->config_get('SubmitWorkersMax');

    my $submit_capacity                             = Bio::EnsEMBL::Hive::Limiter->new( $valley->config_get('SubmitWorkersMax') );
    my $queen_capacity                              = Bio::EnsEMBL::Hive::Limiter->new( 1.0 - $queen->get_hive_current_load() );
    my %meadow_capacity                             = map { $_ => Bio::EnsEMBL::Hive::Limiter->new( $available_worker_slots_by_meadow_type->{$_} ) } keys %$available_worker_slots_by_meadow_type;

    foreach my $analysis_stats (@suitable_analyses) {
        last if( $submit_capacity->reached or $queen_capacity->reached);

        my $analysis            = $analysis_stats->get_analysis;    # FIXME: if it proves too expensive we may need to consider caching
        my $this_meadow_type    = $analysis->meadow_type || $default_meadow_type;

        next if( $meadow_capacity{$this_meadow_type}->reached );

            #digging deeper under the surface so need to sync:
        if(($analysis_stats->status eq 'LOADING') or ($analysis_stats->status eq 'BLOCKED') or ($analysis_stats->status eq 'ALL_CLAIMED')) {
            $queen->synchronize_AnalysisStats($analysis_stats);
        }
        next if($analysis_stats->status eq 'BLOCKED');

            # getting the initial worker requirement for this analysis (may be stale if not sync'ed recently)
        my $workers_this_analysis = $analysis_stats->num_required_workers
            or next;

            # setting up all negotiating limiters:
        $queen_capacity->multiplier( $analysis_stats->hive_capacity );

            # negotiations:
        $workers_this_analysis = $submit_capacity->preliminary_offer( $workers_this_analysis );
        $workers_this_analysis = $queen_capacity->preliminary_offer( $workers_this_analysis );
        $workers_this_analysis = $meadow_capacity{$this_meadow_type}->preliminary_offer( $workers_this_analysis );

            # do not continue with this analysis if haven't agreed on a positive number:
        next unless($workers_this_analysis);

            # let all parties know the final decision of negotiations:
        $submit_capacity->final_decision(                     $workers_this_analysis );
        $queen_capacity->final_decision(                      $workers_this_analysis );
        $meadow_capacity{$this_meadow_type}->final_decision(  $workers_this_analysis );

        my $this_rc_name    = $analysis_id2rc_name->{ $analysis_stats->analysis_id };
        $workers_to_submit_by_meadow_type_rc_name{ $this_meadow_type }{ $this_rc_name } += $workers_this_analysis;
        $total_workers_to_submit                                                        += $workers_this_analysis;
        $analysis_stats->print_stats();
        printf("Before checking the Valley for pending jobs, Scheduler allocated $workers_this_analysis x $this_meadow_type:$this_rc_name workers for '%s' [%.4f hive_load remaining]\n",
            $analysis->logic_name,
            $queen_capacity->available_capacity,
        );
    }

    return (\%workers_to_submit_by_meadow_type_rc_name, $total_workers_to_submit);
}


1;

