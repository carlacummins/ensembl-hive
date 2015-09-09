package Bio::EnsEMBL::Hive::HivePipeline;

use strict;
use warnings;

use Bio::EnsEMBL::Hive::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Hive::Utils ('stringify');
use Bio::EnsEMBL::Hive::Utils::Collection;


sub hive_dba {      # The adaptor for HivePipeline objects
    my $self = shift @_;

    if(@_) {
        $self->{'_hive_dba'} = shift @_;
        $self->{'_hive_dba'}->hive_pipeline($self) if $self->{'_hive_dba'};
    }
    return $self->{'_hive_dba'};
}


sub collection_of {
    my $self = shift @_;
    my $type = shift @_;

    if (@_) {
        warn "set the $type collection";
        $self->{'_cache_by_class'}->{$type} = shift @_;
    } elsif (not $self->{'_cache_by_class'}->{$type}) {
        $self->load_collections( [$type] );
    }

    return $self->{'_cache_by_class'}->{$type};
}


sub new {       # construct an attached or a detached Pipeline object
    my $class           = shift @_;

    my $self = bless {}, $class;

    my %dba_flags           = @_;
    my $existing_dba        = delete $dba_flags{'-dba'};

    if(%dba_flags) {
        my $hive_dba    = Bio::EnsEMBL::Hive::DBSQL::DBAdaptor->new( %dba_flags );
        $self->hive_dba( $hive_dba );
    } elsif ($existing_dba) {
        $self->hive_dba( $existing_dba );
    } else {
        $self->init_collections();
    }

    return $self;
}


sub init_collections {
    my $self = shift @_;

    # If there is a DBAdaptor, collection_of() will call load_collections() on demand
    if ($self->hive_dba) {
        delete $self->{'_cache_by_class'};
        return;
    }

    # Otherwise, we need to explicitly reset all the collections
    foreach my $AdaptorType ('MetaParameters', 'PipelineWideParameters', 'ResourceClass', 'ResourceDescription', 'Analysis', 'AnalysisStats', 'AnalysisCtrlRule', 'DataflowRule') {
        $self->collection_of( $AdaptorType, Bio::EnsEMBL::Hive::Utils::Collection->new() );
    }
}


sub load_collections {
    my $self                = shift @_;
    my $load_collections    = shift @_
                        || [ 'MetaParameters', 'PipelineWideParameters', 'ResourceClass', 'ResourceDescription', 'Analysis', 'AnalysisStats', 'AnalysisCtrlRule', 'DataflowRule' ];

    my $hive_dba = $self->hive_dba();

    foreach my $AdaptorType ( @$load_collections ) {
        my $adaptor = $hive_dba->get_adaptor( $AdaptorType );
        my $all_objects = $adaptor->fetch_all();
        if (@$all_objects and UNIVERSAL::isa($all_objects->[0], 'Bio::EnsEMBL::Hive::Cacheable')) {
            $_->hive_pipeline($self) for @$all_objects;
        }
        $self->collection_of( $AdaptorType, Bio::EnsEMBL::Hive::Utils::Collection->new( $all_objects ) );
    }
}


sub save_collections {
    my $self = shift @_;

    my $hive_dba = $self->hive_dba();

    foreach my $AdaptorType ('MetaParameters', 'PipelineWideParameters', 'ResourceClass', 'ResourceDescription', 'Analysis', 'AnalysisStats', 'AnalysisCtrlRule', 'DataflowRule') {
        my $adaptor = $hive_dba->get_adaptor( $AdaptorType );
        my $class = 'Bio::EnsEMBL::Hive::'.$AdaptorType;
        foreach my $storable_object ( $self->collection_of( $AdaptorType )->list ) {
            $adaptor->store_or_update_one( $storable_object, $class->unikey() );
#            warn "Stored/updated ".$storable_object->toString()."\n";
        }
    }

    my $job_adaptor = $hive_dba->get_AnalysisJobAdaptor;
    foreach my $analysis ( $self->collection_of( 'Analysis' )->list ) {
        if(my $our_jobs = $analysis->jobs_collection ) {
            $job_adaptor->store( $our_jobs );
            foreach my $job (@$our_jobs) {
#                warn "Stored ".$job->toString()."\n";
            }
        }
    }
}


sub add_new_or_update {
    my $self = shift @_;
    my $type = shift @_;

    my $class = 'Bio::EnsEMBL::Hive::'.$type;

    my $object;

    if( my $unikey_keys = $class->unikey() ) {
        my %other_pairs = @_;
        my %unikey_pairs;
        @unikey_pairs{ @$unikey_keys} = delete @other_pairs{ @$unikey_keys };

        if( $object = $self->collection_of( $type )->find_one_by( %unikey_pairs ) ) {
            my $found_display = UNIVERSAL::can($object, 'toString') ? $object->toString : stringify($object);
            if(keys %other_pairs) {
                warn "Updating $found_display with (".stringify(\%other_pairs).")\n";
                if( ref($object) eq 'HASH' ) {
                    @$object{ keys %other_pairs } = values %other_pairs;
                } else {
                    while( my ($key, $value) = each %other_pairs ) {
                        $object->$key($value);
                    }
                }
            } else {
                warn "Found a matching $found_display\n";
            }
        }
    } else {
        warn "$class doesn't redefine unikey(), so unique objects cannot be identified";
    }

    unless( $object ) {
        $object = $class->can('new') ? $class->new( @_ ) : { @_ };

        my $found_display = UNIVERSAL::can($object, 'toString') ? $object->toString : 'naked entry '.stringify($object);
        warn "Created a new $found_display\n";

        $self->collection_of( $type )->add( $object );

        $object->hive_pipeline($self) if UNIVERSAL::isa($object, 'Bio::EnsEMBL::Hive::Cacheable');
    }

    return $object;
}


sub get_meta_value_by_key {
    my ($self, $meta_key) = @_;

    if( my $collection = $self->collection_of( 'MetaParameters' )) {
        my $hash = $collection->find_one_by( 'meta_key', $meta_key );
        return $hash && $hash->{'meta_value'};

    }  else {    # TODO: to be removed when beekeeper.pl/runWorker.pl become collection-aware

        my $adaptor = $self->hive_dba->get_MetaParametersAdaptor;
        my $pair = $adaptor->fetch_by_meta_key( $meta_key );
        return $pair && $pair->{'meta_value'};
    }
}


1;
