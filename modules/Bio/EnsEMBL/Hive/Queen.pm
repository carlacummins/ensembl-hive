#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME
  Bio::EnsEMBL::Hive::Queen

=head1 SYNOPSIS
  The Queen of the Hive based job control system

=head1 DESCRIPTION
  The Queen of the Hive based job control system is responsible to 'birthing' the
  correct number of workers of the right type so that they can find jobs to do.
  It will also free up jobs of Workers that died unexpectantly so that other workers
  can claim them to do.

  Hive based processing is a concept based on a more controlled version
  of an autonomous agent type system.  Each worker is not told what to do
  (like a centralized control system - like the current pipeline system)
  but rather queries a central database for jobs (give me jobs).

  Each worker is linked to an analysis_id, registers its self on creation
  into the Hive, creates a RunnableDB instance of the Analysis->module,
  gets $runnable->batch_size() jobs from the analysis_job table, does its
  work, creates the next layer of analysis_job entries by interfacing to
  the DataflowRuleAdaptor to determine the analyses it needs to pass it's
  output data to and creates jobs on the next analysis's database.
  It repeats this cycle until it's lived it's lifetime or until there are no
  more jobs left.
  The lifetime limit is just a safety limit to prevent these from 'infecting'
  a system.

  The Queens job is to simply birth Workers of the correct analysis_id to get the
  work down.  The only other thing the Queen does is free up jobs that were
  claimed by Workers that died unexpectantly so that other workers can take
  over the work.

  The Beekeeper is in charge of interfacing between the Queen and a compute resource
  or 'compute farm'.  It's job is to query Queens if they need any workers and to
  send the requested number of workers to open machines via the runWorker.pl script.
  It is also responsible for interfacing with the Queen to identify worker which died
  unexpectantly.

=head1 CONTACT
  Contact Jessica Severin on EnsEMBL::Hive implemetation/design detail: jessica@ebi.ac.uk
  Contact Ewan Birney on EnsEMBL in general: birney@sanger.ac.uk

=head1 APPENDIX
  The rest of the documentation details each of the object methods. 
  Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Hive::Queen;

use strict;
use strict;
use Bio::EnsEMBL::Hive::Worker;
use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Sys::Hostname;

our @ISA = qw(Bio::EnsEMBL::DBSQL::BaseAdaptor);

#
# STORE METHODS
#
################

=head2 create_new_worker

  Arg [1]    : $analysis_id
  Example    :
  Description:
  Returntype : Bio::EnsEMBL::Hive::Worker
  Exceptions :
  Caller     :

=cut

sub create_new_worker {
  my ($self,$analysis_id) = @_;

  my $analStatsDBA = $self->db->get_AnalysisStatsAdaptor;
  return undef unless($analStatsDBA);
  
  my $analysisStats = $analStatsDBA->fetch_by_dbID($analysis_id);
  return undef unless($analysisStats);
  $analysisStats->print_stats;
  
  if($analysisStats->status eq 'BLOCKED') {
    print("Analysis is BLOCKED, can't create workers\n");
    return undef;
  }
  if($analysisStats->status eq 'DONE') {
    print("Analysis is DONE, don't need to create workers\n");
    return undef;
  }

  my $host = hostname;
  my $ppid = getppid;

  my $sql = "INSERT INTO hive SET born=now(), last_check_in=now()".
            ",process_id='$ppid' ".
            ",analysis_id='$analysis_id' ".
            ",host='$host'";

  my $sth = $self->prepare($sql);
  $sth->execute();
  my $hive_id = $sth->{'mysql_insertid'};
  $sth->finish;

  my $worker = $self->_fetch_by_hive_id($hive_id);
  $worker=undef unless($worker and $worker->analysis);

  if($worker and $analysisStats) {
    $analysisStats->status('WORKING');
  }
  return $worker;
}


sub register_worker_death {
  my ($self, $worker) = @_;

  return unless($worker);

  # if called without a defined cause_of_death, assume catastrophic failure
  $worker->cause_of_death('FATALITY') unless(defined($worker->cause_of_death));
  
  my $sql = "UPDATE hive SET died=now(), last_check_in=now()";
  $sql .= " ,work_done='" . $worker->work_done . "'";
  $sql .= " ,cause_of_death='". $worker->cause_of_death ."'";
  $sql .= " WHERE hive_id='" . $worker->hive_id ."'";

  my $sth = $self->prepare($sql);
  $sth->execute();
  $sth->finish;

  if($worker->cause_of_death eq "NO_WORK") {
    $self->db->get_AnalysisStatsAdaptor->update_status($worker->analysis->dbID, "ALL_CLAIMED");
  }
  if($worker->cause_of_death eq "FATALITY") {
    #print("FATAL DEATH Arrrrgggghhhhhhhh (hive_id=",$worker->hive_id,")\n");
    $self->db->get_AnalysisJobAdaptor->reset_dead_jobs_for_worker($worker);
  }
}


sub worker_check_in {
  my ($self, $worker) = @_;

  return unless($worker);
  my $sql = "UPDATE hive SET last_check_in=now()";
  $sql .= " WHERE hive_id='" . $worker->hive_id ."'";

  my $sth = $self->prepare($sql);
  $sth->execute();
  $sth->finish;
}


sub fetch_overdue_workers {
  my ($self,$overdue_secs) = @_;

  $overdue_secs = 3600 unless(defined($overdue_secs));

  my $constraint = "h.cause_of_death='' ".
                   "AND (UNIX_TIMESTAMP()-UNIX_TIMESTAMP(h.last_check_in))>$overdue_secs";
  return $self->_generic_fetch($constraint);
}


#
# INTERNAL METHODS
#
###################

=head2 _fetch_by_hive_id

  Arg [1]    : int $id
               the unique database identifier for the feature to be obtained
  Example    : $feat = $adaptor->fetch_by_dbID(1234);
  Description: Returns the feature created from the database defined by the
               the id $id.
  Returntype : Bio::EnsEMBL::Hive::Worker
  Exceptions : thrown if $id is not defined
  Caller     : general

=cut

sub _fetch_by_hive_id{
  my ($self,$id) = @_;

  unless(defined $id) {
    $self->throw("fetch_by_dbID must have an id");
  }

  my @tabs = $self->_tables;

  my $constraint = "h.hive_id = $id";

  #return first element of _generic_fetch list
  my ($obj) = @{$self->_generic_fetch($constraint)};
  return $obj;
}

=head2 _generic_fetch

  Arg [1]    : (optional) string $constraint
               An SQL query constraint (i.e. part of the WHERE clause)
  Arg [2]    : (optional) string $logic_name
               the logic_name of the analysis of the features to obtain
  Example    : $fts = $a->_generic_fetch('contig_id in (1234, 1235)', 'Swall');
  Description: Performs a database fetch and returns feature objects in
               contig coordinates.
  Returntype : listref of Bio::EnsEMBL::SeqFeature in contig coordinates
  Exceptions : none
  Caller     : BaseFeatureAdaptor, ProxyDnaAlignFeatureAdaptor::_generic_fetch

=cut

sub _generic_fetch {
  my ($self, $constraint, $join) = @_;

  my @tables = $self->_tables;
  my $columns = join(', ', $self->_columns());

  if ($join) {
    foreach my $single_join (@{$join}) {
      my ($tablename, $condition, $extra_columns) = @{$single_join};
      if ($tablename && $condition) {
        push @tables, $tablename;

        if($constraint) {
          $constraint .= " AND $condition";
        } else {
          $constraint = " $condition";
        }
      }
      if ($extra_columns) {
        $columns .= ", " . join(', ', @{$extra_columns});
      }
    }
  }

  #construct a nice table string like 'table1 t1, table2 t2'
  my $tablenames = join(', ', map({ join(' ', @$_) } @tables));

  my $sql = "SELECT $columns FROM $tablenames";

  my $default_where = $self->_default_where_clause;
  my $final_clause = $self->_final_clause;

  #append a where clause if it was defined
  if($constraint) {
    $sql .= " WHERE $constraint ";
    if($default_where) {
      $sql .= " AND $default_where ";
    }
  } elsif($default_where) {
    $sql .= " WHERE $default_where ";
  }

  #append additional clauses which may have been defined
  $sql .= " $final_clause";

  my $sth = $self->prepare($sql);
  $sth->execute;

#  print STDERR $sql,"\n";

  return $self->_objs_from_sth($sth);
}

sub _tables {
  my $self = shift;

  return (['hive', 'h']);
}

sub _columns {
  my $self = shift;

  return qw (h.hive_id
             h.analysis_id
             h.host
             h.process_id
             h.work_done
             h.born
             h.last_check_in
             h.died
             h.cause_of_death
            );
}

sub _objs_from_sth {
  my ($self, $sth) = @_;

  my %column;
  $sth->bind_columns( \( @column{ @{$sth->{NAME_lc} } } ));

  my @workers = ();

  while ($sth->fetch()) {
    my $worker = new Bio::EnsEMBL::Hive::Worker;
    $worker->init;

    $worker->hive_id($column{'hive_id'});
    $worker->host($column{'host'});
    $worker->process_id($column{'process_id'});
    $worker->work_done($column{'work_done'});
    $worker->born($column{'born'});
    $worker->last_check_in($column{'last_check_in'});
    $worker->died($column{'died'});
    $worker->cause_of_death($column{'cause_of_death'});
    $worker->adaptor($self);
    $worker->db($self->db);

    if($column{'analysis_id'} and $self->db->get_AnalysisAdaptor) {
      $worker->analysis($self->db->get_AnalysisAdaptor->fetch_by_dbID($column{'analysis_id'}));
    }

    push @workers, $worker;
  }
  $sth->finish;

  return \@workers
}

sub _default_where_clause {
  my $self = shift;
  return '';
}

sub _final_clause {
  my $self = shift;
  return '';
}


1;
