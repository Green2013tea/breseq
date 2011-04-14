###
# Pod Documentation
###

=head1 NAME

Breseq::MutationPredictor

=head1 SYNOPSIS

Perl modules used internally by breseq.

=head1 AUTHOR

Jeffrey E. Barrick <jeffrey.e.barrick@gmail.com>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2010 Michigan State University

breseq is free software; you can redistribute it and/or modify it under the terms the 
GNU General Public License as published by the Free Software Foundation; either 
version 1, or (at your option) any later version.

=cut

###
# End Pod Documentation
###

package Breseq::MutationPredictor;
use vars qw(@ISA);
use strict;

use Bio::Root::Root;
use Data::Dumper;


@ISA = qw( Bio::Root::Root );


=head2 new

 Title   : new
 Usage   : $gd = Breseq::GenomeDiff->new();
           $gd = Breseq::GenomeDiff->new( -file => 'evolved.gd' );
 Function: Creates a GenomeDiff object, loading it from a file if one is provided
 Returns : new GenomeDiff object

=cut

sub new
{
	my($caller,@args) = @_;
	my $class = ref($caller) || $caller;
	my $self = new Bio::Root::Root($caller, @args);	
	bless ($self, $class);
	
	# initialize options
	$self->{ref_seq_info} = $self->Bio::Root::RootI::_rearrange([qw(REF_SEQ_INFO)], @args);
	$self->throw("Must provide -ref_seq_info to constructor.") if (!defined $self->{ref_seq_info});
	
	$self->{mutation_log10_e_value_cutoff} = $self->Bio::Root::RootI::_rearrange([qw(MUTATION_LOG10_E_VALUE_CUTOFF)], @args);
	$self->{mutation_log10_e_value_cutoff} = 2 if (!defined $self->{mutation_log10_e_value_cutoff});

	return $self;
}


=head2 predict

 Title   : predict
 Usage   : $mp->predict();
 Function: Predicts mutations from evidence in a GenomeDiff and adds them to it
 Returns : 

=cut
sub predict
{
	our $verbose = 0;
	our ($self, $settings, $summary, $ref_seq_info, $gd) = @_;
	
	## Utility function
	sub get_sequence
	{
		my ($seq_id, $start, $end) = @_;
		print "Get sequence: $seq_id:$start-$end\n" if ($verbose);
		return substr $ref_seq_info->{ref_strings}->{$seq_id}, $start-1, $end-$start+1;
	}
	
	###
	##  Preprocessing of JC evidence
	###
	
	##For all that follows, we need information about repeat_regions overlapping the sides of junctions	
	my @jc = $gd->list('JC');
	
	JC: foreach my $j (@jc)
	{
		$j->{_side_1_read_side} = -1;
		$j->{_side_2_read_side} = +1;					

		foreach my $side_key ('side_1', 'side_2')
		{						
			$j->{"_$side_key\_is"} = Breseq::ReferenceSequence::find_closest_repeat_region(
				$j->{"$side_key\_position"}, 
				$ref_seq_info->{repeat_lists}->{$j->{"$side_key\_seq_id"}}, 
				50, 
				$j->{"$side_key\_strand"}
			);
			
			$j->{"$side_key\_annotate_key"} = ((defined $j->{"_$side_key\_is"}) || ($j->{"$side_key\_redundant"})) ? 'repeat' : 'gene';				
		}
		
		## by default, we are sorted by this coord
		$j->{_unique_interval} = 'side_1';
		
		## Determine which side of the junction is the IS and which is unique
		## these point to the correct initial interval...
		if (defined $j->{_side_1_is})
		{	
			if (abs($j->{_side_1_is}->{start} - $j->{side_1_position}) <= 20)
			{
				$j->{_is_interval} = 'side_1';
				$j->{_is_interval_closest_side_key} = 'start';
				$j->{_unique_interval} = 'side_2';	
			}
			elsif (abs($j->{_side_1_is}->{end} - $j->{side_1_position}) <= 20 )
			{
				$j->{_is_interval} = 'side_1';
				$j->{_is_interval_closest_side_key} = 'end';
				$j->{_unique_interval} = 'side_2';		
			}			
		}
		elsif (defined $j->{_side_2_is})
		{
			if (abs($j->{_side_2_is}->{start} - $j->{side_2_position}) <= 20)
			{
				$j->{_is_interval} = 'side_2';
				$j->{_is_interval_closest_side_key} = 'start';
				$j->{_unique_interval} = 'side_1';
			}
			elsif (abs($j->{_side_2_is}->{end} - $j->{side_2_position}) <= 20 )
			{
				$j->{_is_interval} = 'side_2';
				$j->{_is_interval_closest_side_key} = 'end';
				$j->{_unique_interval} = 'side_1';
			}
		}
	}
	@jc = grep { !$_->{reject} } @jc; 
	## Don't count rejected ones, this can be relaxed, but it makes MOB prediction much more complicated and prone to errors.

	
	my @mc = $gd->list('MC');	
		
	###
	## evidence MC + JC => DEL mutation
	###

	## DEL prediction:
	## (1) there is a junction that exactly crosses the deletion boundary deletion
	## (2) there is is no junction, but both ends of the deletion are in repeat sequences
	## (3) there is a junction between unique sequence and a repeat element

	MC: foreach my $mc_item (@mc)
	{
		next if ($mc_item->{reject});

		#set up generic deletion item
		my $mut = { 
			type => 'DEL',
			seq_id => $mc_item->{seq_id},
			position => $mc_item->{start},
			size => $mc_item->{end} - $mc_item->{start} + 1,
			evidence => [$mc_item->{id}],
		};			

		###
		## (1) there is a junction that exactly crosses the deletion boundary deletion
		###
		
		JUNCTION: for (my $i=0; $i < scalar @jc; $i++)
		{
			my $jc_item = $jc[$i];
			
			next if ($jc_item->{side_1_seq_id} ne $mut->{seq_id});
			next if ($jc_item->{side_2_seq_id} ne $mut->{seq_id});

			## We always know that the lower coordinate part of the junction is first, hence these
			## assumptions about the strands hold.
			if (  ($jc_item->{side_1_position} == $mut->{position}-1) && ($jc_item->{side_1_strand} == -1)
			   && ($jc_item->{side_2_position} == $mut->{position}+$mut->{size}) && ($jc_item->{side_2_strand} == +1) )
			{
				push @{$mut->{evidence}}, $jc_item->{id};
				splice @jc, $i, 1; 
				$i--;
				$gd->add($mut);
				next MC;
			}
		}
		
		sub within_repeat
		{
			my ($seq_id, $position) = @_;
			foreach my $r (@{$self->{ref_seq_info}->{repeat_lists}->{$seq_id}})
			{
				return $r if ($r->{start} <= $position) && ($position <= $r->{end})
			}
			return undef;
		}

		###
		## (2) there is is no junction, but both ends of the deletion are in repeat sequences
		###
		
		my $r1 = within_repeat($mut->{seq_id}, $mut->{position}); 
		my $r2 = within_repeat($mut->{seq_id}, $mut->{position} + $mut->{size}); 
		
		## Then we will adjust the coordinates to remove...
		if (defined $r1 && defined $r2 && ($r1->{name} eq $r2->{name}))
		{
			#there may be more evidence that one or the other is deleted...
			my $r1_overlap_end = $mc_item->{start} + $mc_item->{start_range};
			$r1_overlap_end = $r1->{end} if ($r1_overlap_end > $r1->{end});
			my $r1_overlap = $r1_overlap_end - $mc_item->{start} + 1;
			
			my $r2_overlap_start = $mc_item->{end} - $mc_item->{end_range};
			$r2_overlap_start = $r2->{start} if ($r2_overlap_start < $r1->{start});
			my $r2_overlap = $mc_item->{end} - $r2_overlap_start + 1;				
			
			# it may be really close...defined by read length of genome in which case
			my $slop_distance = $summary->{sequence_conversion}->{max_read_length};
			
			## prefer to delete the second copy
			if ((abs($r1_overlap - $r2_overlap) <= $slop_distance) || ($r2_overlap > $r1_overlap ))
			{
				$mut->{position} = $r1->{end} + 1;
				$mut->{size} = $r2->{end} - $r1->{end};
			}
			else #delete the first copy
			{
				$mut->{position} = $r1->{start};
				$mut->{size} = $r2->{start} - $r1->{start};
			}				
			
			## remember the name of the element
			$mut->{between} = $r1->{name};
			$gd->add($mut);	
			next MC;			
		}
		
		## Both sides were unique or redundant, nothing more we can do...
		next MC if (!defined $r1 && !defined $r2);
		next MC if (defined $r1 && defined $r2);
		
		###
		## (3) there is a junction between unique sequence and a repeat element
		###
		my $r = (defined $r1) ? $r1 : $r2; 
		my $redundant_deletion_side = (defined $r1) ? -1 : +1; 
		my $unique_deletion_strand = -$redundant_deletion_side; 
		my $needed_coord = (defined $r1) ?  $mut->{position}+$mut->{size} : $mut->{position} - 1;
				
		JUNCTION: for (my $i=0; $i < scalar @jc; $i++)
		{
			my $j = $jc[$i];

			next JUNCTION if (!defined $j->{_is_interval});
			
			print "Check 1: " . $j->{"$j->{_unique_interval}_seq_id"} . " ne $mut->{seq_id}\n" if ($verbose);
			next JUNCTION if ($j->{"$j->{_unique_interval}_seq_id"} ne $mut->{seq_id});
			print "Pass 1\n" if ($verbose);

			#check type of IS
			print "Check 2: " . $r->{name} . " ne " .  $j->{"_$j->{_is_interval}_is"}->{name} . "\n" if ($verbose);			
			next JUNCTION if ( $r->{name} ne $j->{"_$j->{_is_interval}_is"}->{name} );
			print "Pass 2\n" if ($verbose);
			
			#check that the unique side matches coordinate
			print "Check 3: " . $j->{"$j->{_unique_interval}\_position"} . " != " .  $needed_coord . "\n" if ($verbose);			
			next JUNCTION if ( $j->{"$j->{_unique_interval}\_position"} != $needed_coord );
			print "Pass 3\n" if ($verbose);

			print Dumper($mut) if ($verbose);
			print Dumper($j) if ($verbose);
			print Dumper($r) if ($verbose);

			#check that IS is on the right strand
			print "Check 4: " . $redundant_deletion_side . " * " . $r->{strand} . " != " .  $j->{"$j->{_is_interval}\_strand"}  . " * " . $j->{"_$j->{_is_interval}_is"}->{strand} . "\n" if ($verbose);							
			next JUNCTION if ( $redundant_deletion_side * $r->{strand} !=  $j->{"$j->{_is_interval}\_strand"} * $j->{"_$j->{_is_interval}_is"}->{strand} );
			print "Pass 4\n" if ($verbose);

			#check that the unique side is on the right strand	 
			print "Check 5: " . $unique_deletion_strand . " != " .  $j->{"$j->{_unique_interval}\_strand"} . "\n" if ($verbose);				
			next JUNCTION if ( $unique_deletion_strand != $j->{"$j->{_unique_interval}\_strand"} );
			print "Pass 5\n" if ($verbose);

			## need to adjust the non-unique coords
			if ($redundant_deletion_side == -1)
			{
				my $move_dist = $r->{end} + 1 - $mut->{position};
				$mut->{position} += $move_dist;
				$mut->{size} -= $move_dist;
			}
			else
			{
				my $move_dist = ($mut->{position} + $mut->{size} - 1) - ($r->{start}-1);
				$mut->{size} -= $move_dist;
			}

			## OK, we're good!
			$mut->{mediated} = $r->{name};
			push @{$mut->{evidence}}, $j->{id};
			splice @jc, $i, 1; 
			$i--;
			$gd->add($mut);
			next MC;
		}
						
	}
	
	
	###
	## evidence JC + JC = MOB mutation
	###
	
	JC: foreach my $j (@jc)
	{					
		## Ah, we don't have an IS, we are done
		next JC if (!defined $j->{_is_interval});
		
		## Ah, there is no overlap to play with, we are done
		next JC if ($j->{overlap} <= 0);
		
		## The following code implies $j->{overlap} > 0
				
		### first, adjust the repetitive sequence boundary to get as close to the IS as possible
		my $move_dist = abs($j->{"$j->{_is_interval}\_position"} - $j->{"_$j->{_is_interval}\_is"}->{$j->{_is_interval_closest_side_key}});
		$move_dist = $j->{overlap} if ($move_dist > $j->{overlap});
		$j->{"$j->{_is_interval}\_position"} += $j->{"$j->{_is_interval}\_strand"} * $move_dist;
		$j->{overlap} -= $move_dist;
		
		### second, adjust the unique sequence side with any remaining overlap
		$j->{"$j->{_unique_interval}\_position"} += $j->{"$j->{_unique_interval}\_strand"} * $j->{overlap};						
					
		$j->{overlap} = 0;
	}
	

	sub by_hybrid
	{
		my $a_pos = (defined $a->{_side_1_is}) ? $a->{_side_2}->{position} : $a->{_side_1}->{position};
		my $b_pos = (defined $b->{_side_1_is}) ? $b->{_side_2}->{position} : $b->{_side_1}->{position};

		my $a_seq_order = (defined $a->{_side_1_is}) ? $ref_seq_info->{seq_order}->{$a->{_side_2}->{seq_id}} : $ref_seq_info->{seq_order}->{$a->{_side_1}->{seq_id}};
		my $b_seq_order = (defined $b->{_side_1_is}) ? $ref_seq_info->{seq_order}->{$b->{_side_2}->{seq_id}} : $ref_seq_info->{seq_order}->{$b->{_side_1}->{seq_id}};		

		my $a_reject_order = scalar Breseq::GenomeDiff::number_reject_reasons($a);
		my $b_reject_order = scalar Breseq::GenomeDiff::number_reject_reasons($b);

		## sort by seq_id, position, fewer reject reasons, then score (highest to lowest)
		return (
			($a_seq_order <=> $b_seq_order) 
			|| ($a_pos <=> $b_pos) 
			|| ($a_reject_order <=> $b_reject_order) 
			|| -($a->{pos_hash_score} <=> $b->{pos_hash_score})
			|| -($a->{min_overlap_score} <=> $b->{min_overlap_score})
		);
	}
	@jc = sort by_hybrid @jc;
	
		
	JC1: foreach (my $i=0; $i<scalar(@jc)-1; $i++)
	{	
		my $j1 = $jc[$i];
		
		#Compile a list of the next possibilities within a certain length of bases
		my @j2_list;
		my $j=1;
		JC2: while ($i+$j<scalar(@jc))
		{
			my $j2 = $jc[$i+$j];
			
			#must be close together in real coords
			last JC2 if ($j1->{"$j1->{_unique_interval}\_seq_id"} ne $j2->{"$j2->{_unique_interval}\_seq_id"});
			last JC2 if ( abs($j1->{"$j1->{_unique_interval}\_position"} - $j2->{"$j2->{_unique_interval}\_position"}) > 20 );

			next JC2 if (!defined $j1->{_is_interval} || !defined $j2->{_is_interval});
			next JC2 if ($j1->{"_$j1->{_is_interval}\_is"}->{name} ne $j2->{"_$j2->{_is_interval}\_is"}->{name});
			
			push @j2_list, $j2;
			$j2->{_delete_index} = $i+$j; #for remembering what to delete if this one succeeds
			
		} continue {
			$j++;
		}
		
		#sort the $j2_list by reject reason and score

		sub by_reject_score
		{
			my $a_reject_order = scalar Breseq::GenomeDiff::number_reject_reasons($a);
			my $b_reject_order = scalar Breseq::GenomeDiff::number_reject_reasons($b);
			## sort by seq_id, position, fewer reject reasons, then score (highest to lowest)
			return (($a_reject_order <=> $b_reject_order) || -($a->{score} <=> $b->{score}));
		}
		@j2_list = sort by_reject_score @j2_list;

		## We need to go through all with the same coordinate (or within a certain coordinate stretch?)
		## because sometimes a failed junction will be in between the successful junctions
		JC2: foreach my $j2 (@j2_list)
		{			
			## positive overlap should be resolved by now
			#die if ($j1->{overlap} > 0);
			#die if ($j2->{overlap} > 0);

			#the first unique coords are going into the IS element
			my $uc1_strand = $j1->{"$j1->{_unique_interval}\_strand"};
			my $uc2_strand = $j2->{"$j2->{_unique_interval}\_strand"};
			next if ($uc1_strand != -$uc2_strand);

			## What strand is the IS on relative to the top strand of the genome
			my $is1_strand = - $j1->{"$j1->{_is_interval}\_strand"} * $j1->{"_$j1->{_is_interval}\_is"}->{strand} * $j1->{"$j1->{_unique_interval}\_strand"};
			my $is2_strand = - $j2->{"$j2->{_is_interval}\_strand"} * $j2->{"_$j2->{_is_interval}\_is"}->{strand} * $j2->{"$j2->{_unique_interval}\_strand"};

			## Remove these predictions from the list, $j2 first, so indices don't shift
			splice @jc, $j2->{_delete_index}, 1; 
			splice @jc, $i, 1; 
			$i-=1; ## only minus one b/c the current one was deleted
				
			# Create the mutation, with evidence
			my $mut = { 
				type => 'MOB',
				seq_id => $j1->{"$j1->{_unique_interval}\_seq_id"},
				evidence => [ $j1->{id}, $j2->{id} ],
			};

			$mut->{_start} = ($uc1_strand == -1) ? $j2->{"$j2->{_unique_interval}\_position"} : $j1->{"$j1->{_unique_interval}\_position"};
			$mut->{_end} = ($uc1_strand == -1) ? $j1->{"$j1->{_unique_interval}\_position"} : $j2->{"$j2->{_unique_interval}\_position"};
			$mut->{repeat_name} = $j1->{"_$j1->{_is_interval}\_is"}->{name};

			print Dumper($j1, $j2) if ($verbose);	

			$mut->{position} = $mut->{_start}; ## - 1; #position is the first duplicated base...
 			$mut->{duplication_size} = $mut->{_end} - $mut->{_start} + 1;
				
			## ok, we're actually missing a base of the reference...
			if ($mut->{duplication_size} < 0)
			{
				$mut->{position} += $mut->{duplication_size};
			}
			
			## get any unique junction sequence
			my $j1i = Breseq::Shared::junction_name_split($j1->{key});
			my $j1_unique_read_sequence = $j1i->{unique_read_sequence};

			my $j2i = Breseq::Shared::junction_name_split($j2->{key});
			my $j2_unique_read_sequence = $j2i->{unique_read_sequence};
		
			## _gap_left and _gap_right also refer to the top strand of the genome

			$mut->{_ins_start} = '';
			$mut->{_ins_end} = '';

			$mut->{_del_start} = 0;
			$mut->{_del_end} = 0;
		
			#sometimes the ends of the IS are not quite flush
			my $j1_not_flush_seq = '';
			if ($j1->{"$j1->{_is_interval}\_strand"} == -1)
			{
				$mut->{_gap_left} = $j1->{"$j1->{_is_interval}\_position"} - $j1->{"_$j1->{_is_interval}\_is"}->{end};
				
				if ($mut->{_gap_left} > 0)
				{
					$j1_not_flush_seq = get_sequence (
						$j1->{"$j1->{_is_interval}\_seq_id"}, 
						$j1->{"_$j1->{_is_interval}\_is"}->{end}+1, 
						$j1->{"$j1->{_is_interval}\_position"}
					);
				}
			}
			else
			{
				$mut->{_gap_left} = $j1->{"_$j1->{_is_interval}\_is"}->{start} - $j1->{"$j1->{_is_interval}\_position"};
				if ($mut->{_gap_left} > 0)
				{
					$j1_not_flush_seq = get_sequence (
						$j1->{"$j1->{_is_interval}\_seq_id"}, 
						$j1->{"$j1->{_is_interval}\_position"}, 
						$j1->{"_$j1->{_is_interval}\_is"}->{start} - 1
					);
				}
			}

			if ($mut->{_gap_left} >= 0)
			{
				print "J1 NF:$j1_not_flush_seq U:$j1_unique_read_sequence\n" if ($verbose);
				
				if ($j1->{"_$j1->{_is_interval}\_read_side"} * $j1->{"$j1->{_is_interval}\_strand"} == -1)
				{
					$j1_not_flush_seq = Breseq::Fastq::revcom($j1_not_flush_seq);
				}
				
				if ($j1->{"_$j1->{_is_interval}\_read_side"} == -1)
				{
					$mut->{_gap_left} = $j1_not_flush_seq . $j1_unique_read_sequence;
				}
				else
				{
					$mut->{_gap_left} = $j1_unique_read_sequence . $j1_not_flush_seq;
				}
				$mut->{_ins_start} = $mut->{_gap_left};
			}
			elsif ($mut->{_gap_left} < 0)
			{
				$mut->{_del_start} = abs($mut->{_gap_left});
			}

			my $j2_not_flush_seq = '';
			if ($j2->{"$j2->{_is_interval}\_strand"} == -1)
			{
				$mut->{_gap_right} = $j2->{"$j2->{_is_interval}\_position"} - $j2->{"_$j2->{_is_interval}\_is"}->{end};
				if ($mut->{_gap_right} > 0)
				{
					$j2_not_flush_seq= get_sequence (
						$j1->{"$j2->{_is_interval}\_seq_id"}, 
						$j2->{"_$j2->{_is_interval}\_is"}->{end} + 1, 
						$j2->{"$j2->{_is_interval}\_position"}
					);
				}
			}
			else
			{
				$mut->{_gap_right} = $j2->{"_$j2->{_is_interval}\_is"}->{start} - $j2->{"$j2->{_is_interval}\_position"};
				if ($mut->{_gap_right} > 0)
				{
					$j2_not_flush_seq = get_sequence (
						$j1->{"$j2->{_is_interval}\_seq_id"}, 
						$j2->{"$j2->{_is_interval}\_position"}, 
						$j2->{"_$j2->{_is_interval}\_is"}->{start} - 1
					);
				}
			}
			
			
			if ($mut->{_gap_right} >= 0)
			{
				print "J2 NF:$j2_not_flush_seq U:$j2_unique_read_sequence\n" if ($verbose);
				
				if ($j2->{"_$j2->{_is_interval}\_read_side"} * $j2->{"$j2->{_is_interval}\_strand"} == -1)
				{
					$j2_not_flush_seq = Breseq::Fastq::revcom($j2_not_flush_seq);
				}
				
				if ($j2->{"_$j2->{_is_interval}\_read_side"} == -1)
				{
					$mut->{_gap_right} = $j2_not_flush_seq . $j2_unique_read_sequence;
				}
				else
				{
					$mut->{_gap_right} = $j2_unique_read_sequence . $j2_not_flush_seq;
				}
				$mut->{_ins_end} = $mut->{_gap_right};
			}
			elsif ($mut->{_gap_right} < 0)
			{
				$mut->{_del_end} = abs($mut->{_gap_right});
			}

			## At this point any added junction sequences are on the strand as you would see them in the alignment.
			## we may need to reverse complement and change sides.

			print "$mut->{_gap_left} :: $mut->{_gap_right}\n" if ($verbose);

			if ($j1->{"$j1->{_unique_interval}\_strand"} *  $j1->{"_$j1->{_unique_interval}\_read_side"} == -1)
			{
				print "RC left\n" if ($verbose);
				$mut->{_ins_start} = Breseq::Fastq::revcom($mut->{_ins_start});
				
			}

			if ($j2->{"$j2->{_unique_interval}\_strand"} *  $j2->{"_$j2->{_unique_interval}\_read_side"} == -1)
			{
				print "RC right\n" if ($verbose);
				$mut->{_ins_end} = Breseq::Fastq::revcom($mut->{_ins_end});
			}

			#### Check for ambiguous insertion direction!
			## Sometimes a strand will be assigned just because there is a 50-50 chance of getting the correct sides of the IS.
			## We need to actually check the sequence on each side of the repeat element on the end as far in as the maximum overlap on that side.
			## Use:			{max_left} {max_right}
			## Retrieve sequence on unique side and compare to sequence on the other side of a repeat element
			
			my $j1_not_flush_length = length($j1_not_flush_seq);
			my $j2_not_flush_length = length($j2_not_flush_seq);
			my $max_not_flush_length = ($j1_not_flush_length > $j2_not_flush_length) ? $j1_not_flush_length : $j2_not_flush_length;

			print "J1 not flush length: $j1_not_flush_length\n" if ($verbose);
			print "J2 not flush length: $j2_not_flush_length\n" if ($verbose);
			print "Max not flush length: $max_not_flush_length\n" if ($verbose);
			
			my $j1_is_overlap_length = ($j1->{"_$j1->{_is_interval}\_read_side"} == -1) ? $j1->{max_left} : $j1->{max_right};
			my $j2_is_overlap_length = ($j2->{"_$j2->{_is_interval}\_read_side"} == -1) ? $j2->{max_left} : $j2->{max_right};

			print "J1 IS overlap length: $j1_is_overlap_length\n" if ($verbose);
			print "J2 IS overlap length: $j2_is_overlap_length\n" if ($verbose);

			my $j1_is_seq_matched = '';
			if ($j1->{"$j1->{_is_interval}\_strand"} == -1)
			{
				$j1_is_seq_matched = get_sequence (
					$j1->{"$j1->{_is_interval}\_seq_id"},
					$j1->{"$j1->{_is_interval}\_position"} - ($j1_is_overlap_length - 1),
					$j1->{"$j1->{_is_interval}\_position"} - $j1_not_flush_length
				);
				$j1_is_seq_matched = Breseq::Fastq::revcom($j1_is_seq_matched);
			}
			else
			{
				$j1_is_seq_matched = get_sequence (
					$j1->{"$j1->{_is_interval}\_seq_id"},
					$j1->{"$j1->{_is_interval}\_position"} + $j1_not_flush_length,
					$j1->{"$j1->{_is_interval}\_position"} + $j1_is_overlap_length - 1
				);
			}
			
			my $j2_is_seq_matched = '';			
			if ($j2->{"$j2->{_is_interval}\_strand"} == -1)
			{
				$j2_is_seq_matched = get_sequence (
					$j2->{"$j2->{_is_interval}\_seq_id"},
					$j2->{"$j2->{_is_interval}\_position"} - ($j2_is_overlap_length - 1),
					$j2->{"$j2->{_is_interval}\_position"} - $j2_not_flush_length
				);
				$j2_is_seq_matched = Breseq::Fastq::revcom($j2_is_seq_matched);
			}
			else
			{
				$j2_is_seq_matched = get_sequence (
					$j2->{"$j2->{_is_interval}\_seq_id"},
					$j2->{"$j2->{_is_interval}\_position"} + $j2_not_flush_length,
					$j2->{"$j2->{_is_interval}\_position"} + $j2_is_overlap_length - 1
				);
			}
			
			## what are the actual sequences of this length at the end of the IS elements?
				
			my $j1_left_is_sequence = get_sequence (
				$j1->{"$j1->{_is_interval}\_seq_id"},
				$j1->{"_$j1->{_is_interval}\_is"}->{start},
				$j1->{"_$j1->{_is_interval}\_is"}->{start} + $j1_is_overlap_length - 1
			);

			my $j1_right_is_sequence = get_sequence (
				$j1->{"$j1->{_is_interval}\_seq_id"},
				$j1->{"_$j1->{_is_interval}\_is"}->{end} - ($j1_is_overlap_length - 1),
				$j1->{"_$j1->{_is_interval}\_is"}->{end}
			);
			$j1_right_is_sequence = Breseq::Fastq::revcom($j1_right_is_sequence);
			
			print "J1 LEFT : $j1_left_is_sequence\n" if ($verbose);
			print "J1 RIGHT: $j1_right_is_sequence\n" if ($verbose);
			
			#believe the direction if the sequences are different
			my $j1_is_ambiguous = ($j1_left_is_sequence eq $j1_right_is_sequence) ? 1 : 0;
				
			my $j2_left_is_sequence = get_sequence (
				$j2->{"$j2->{_is_interval}\_seq_id"},
				$j2->{"_$j2->{_is_interval}\_is"}->{start},
				$j2->{"_$j2->{_is_interval}\_is"}->{start} + $j2_is_overlap_length - 1
			);

			my $j2_right_is_sequence = get_sequence (
				$j2->{"$j2->{_is_interval}\_seq_id"},
				$j2->{"_$j2->{_is_interval}\_is"}->{end} - ($j2_is_overlap_length - 1),
				$j2->{"_$j2->{_is_interval}\_is"}->{end}
			);
			$j2_right_is_sequence = Breseq::Fastq::revcom($j2_right_is_sequence);

			#believe the direction if the sequences are different
			my $j2_is_ambiguous = ($j2_left_is_sequence eq $j2_right_is_sequence) ? 1 : 0;

			
			print "J2 LEFT : $j2_left_is_sequence\n" if ($verbose);
			print "J2 RIGHT: $j2_right_is_sequence\n" if ($verbose);
				
			
			print "J1 IS matched length $j1_is_overlap_length: $j1_is_seq_matched\n" if ($verbose);
			print "J2 IS matched length $j2_is_overlap_length: $j2_is_seq_matched\n" if ($verbose);
						
			## if the matched IS element sequences are the same then the direction is AMBIGUOUS
			my $is_strand = 0;
			if ($j1_is_ambiguous && $j2_is_ambiguous)
			{
				print "AMBIGUOUS strand for mobile element insertion\n" if ($verbose);
			}
			elsif ($j1_is_ambiguous)
			{
				$is_strand = $is2_strand;
			}
			elsif ($j2_is_ambiguous)
			{
				$is_strand = $is1_strand;
			}
			else #neither is ambiguous, hopefully the strands agree
			{
				$is_strand = $is1_strand if ($is1_strand == $is1_strand);
			}
			$mut->{strand} = $is_strand;
			
			####
			#### We are still not checking for a case where one junction side extends far enough to uniquely define the
			#### side of the IS, but the other side does not (giving it the wrong strand).
			
			
			## Finally, do this AFTER checking for the IS-matched sequences...
			#$j1 may be the left side, rather than the right side of the insertion, if so...
			if ($uc1_strand == +1)
			{
				print "reverse right and left\n" if ($verbose);				
				($mut->{_ins_start}, $mut->{_ins_end}) = ($mut->{_ins_end}, $mut->{_ins_start});
				($mut->{_del_start}, $mut->{_del_end}) = ($mut->{_del_end}, $mut->{_del_start});
				
			}	
			
			## clean up unused keys
			$mut->{del_start} = $mut->{_del_start} if ($mut->{_del_start});
			$mut->{del_end} = $mut->{_del_end} if ($mut->{_del_end});

			$mut->{ins_start} = $mut->{_ins_start} if ($mut->{_ins_start});
			$mut->{ins_end} = $mut->{_ins_end} if ($mut->{_ins_end});

			print "$mut->{_gap_left} :: $mut->{_gap_right}\n" if ($verbose);

			$gd->add($mut);
			next JC1;
		}
	}
	
	###
	## evidence JC => INS, SUB, AMP mutations
	###

	JC: foreach my $j (@jc)
	{									
		## must be on same sequence
		next JC if ($j->{_side_1}->{seq_id} ne $j->{_side_2}->{seq_id});
		my $seq_id = $j->{_side_1}->{seq_id};
		
		## must be in same orientation
		next JC if ($j->{_side_1}->{strand} != +1);
		next JC if ($j->{_side_2}->{strand} != -1);

		## We can assume that the lower coordinate will be first since this is NOT a deletion
		## (which would be handled above)
		die if ($j->{overlap} > 0);
		
		## mutation will always be after this position
		my $position = $j->{_side_1}->{position};
		
		## Special case of circular chromosome
		if ( ($j->{_side_1}->{position} == 1) && ($j->{_side_2}->{position} == $summary->{sequence_conversion}->{reference_sequences}->{$seq_id}->{length} ) )
		{
			$j->{circular_chromosome} = 1;
			next;
		}
		##protection against mistakes
		next if ($j->{_side_2}->{position} - $j->{_side_1}->{position} + 1 > 100000);		
		
		## 'AMP'
		if (!$j->{unique_read_sequence})
		{		
			my $size = $j->{_side_2}->{position} - $j->{_side_1}->{position} + 1;
			next if ($size < 0); #this is a deletion!
#			next if ($size > 100); #spurious duplication, need extra evidence from coverage!

			my $mut = { 
				type => 'AMP',
				seq_id => $seq_id,
				position => $position,
				size => $size,
				new_copy_number => 2,
				evidence => [$j->{id}], 
			};			
			$gd->add($mut);
		}
		## 'SUB'
		elsif ($j->{_side_1}->{position} >= $j->{_side_2}->{position})
		{
			my $ref_seq = '';
			my $new_seq = $j->{unique_read_sequence};
			if ($j->{_side_1}->{position} >= $j->{_side_2}->{position})
			{
				$new_seq = get_sequence (
					$seq_id,
					$j->{_side_2}->{position},
					$j->{_side_1}->{position}
				);
			}
			
			my $mut = { 
				type => 'SUB',
				seq_id => $seq_id,
				position => $position,
				size => $j->{_side_1}->{position} - $j->{_side_2}->{position} + 1,
				new_seq => $new_seq,
				evidence => [$j->{id}], 
			};
			$gd->add($mut);
		}
		## 'INS'
		elsif ($j->{_side_1}->{position} + 1 == $j->{_side_2}->{position})
		{
			my $mut = { 
				type => 'INS',
				seq_id => $seq_id,
				position => $position,
				new_seq => $j->{unique_read_sequence},
				evidence => [$j->{id}], 
			};
			$gd->add($mut);
		}
	}


	###
	## Read Alignments => SNP, DEL, INS, SUB
	###		

	my @ra = $gd->list('RA');

	###
	## Ignore RA that overlap DEL or MC
	## They are due to low spurious coverage in deleted regions!
	###
	
	{
		my @del = $gd->list('DEL');	
		my @mc = $gd->list('MC');	
		
		RA: foreach my $ra_item (@ra)
		{
			DEL: foreach my $del_item (@del)
			{
				next DEL if ($ra_item->{seq_id} ne $del_item->{seq_id});
			
				## there might be a problem here with insert_position > 0
				if ( ($ra_item->{position} >= $del_item->{position}) && ($ra_item->{position} <= $del_item->{position} + $del_item->{size} - 1) )
				{
					$ra_item->{deleted} = 1;
					next RA;
				}
			}
			
			MC: foreach my $mc_item (@mc)
			{
				next MC if ($ra_item->{seq_id} ne $mc_item->{seq_id});
			
				if ( ($ra_item->{position} >= $mc_item->{start}) && ($ra_item->{position} <= $mc_item->{end}) )
				{
					$ra_item->{deleted} = 1;
					next RA;
				}
			}
			
		}
	}
		
	## look at SNPs and small indels predicted by read alignments.
	##be sure they are sorted by position
	sub by_pos
	{		
	       ($a->{seq_id} cmp $b->{seq_id})
		|| ($a->{position} <=> $b->{position}) 
		|| ($a->{insert_position} <=> $b->{insert_position})
	}
	@ra = sort by_pos @ra;

	###
	## Gather together read alignment mutations that occur next to each other
	## ...unless they are polymorphisms
	###
	
	my $mut;
	my @muts;
	
	foreach my $item (@ra)
	{
		next if ($item->{reject});
		next if ($item->{deleted}); 
			## Sometimes a SNP might be called in a deleted area because the end was wrong, 
			## but it was corrected using a junction. (This catches this case.)

		my $same = 0;
		if (defined $mut)
		{
			$same = 1 if ($mut->{end} == $item->{position}) && ($mut->{insert_end} + 1 == $item->{insert_position});
			$same = 1 if ($mut->{end} + 1 == $item->{position}) && ($item->{insert_position} == 0);
			$same = 0 if (($item->{frequency} != 1) || ($mut->{frequency} != 1)); #don't join polymorphisms
			$same = 0 if ($mut->{seq_id} ne $item->{seq_id});
		}
		
		if (!$same)
		{
			push @muts, $mut if (defined $mut);
			my $new_mut = { 
				seq_id => $item->{seq_id},
				position => $item->{position},
				start => $item->{position},
				end => $item->{position},
				insert_start => $item->{insert_position},
				insert_end => $item->{insert_position},
				ref_seq => ($item->{ref_base} ne '.') ? $item->{ref_base} : '',
				new_seq => ($item->{new_base} ne '.') ? $item->{new_base} : '',
				evidence => [$item->{id}],
				frequency => $item->{frequency}, 
			};			
			$mut = $new_mut;
		}
		else
		{
			$mut->{insert_end} = $item->{insert_position};
			$mut->{end} = $item->{position};
			$mut->{ref_seq} .= $item->{ref_base} if ($item->{ref_base} ne '.');
			$mut->{new_seq} .= $item->{new_base} if ($item->{new_base} ne '.');
			push @{$mut->{evidence}}, $item->{id}; 
		}
	}	
	##don't forget the last one
	push @muts, $mut if (defined $mut);
	
	###
	## Finally, convert these items into the fields needed for the various types of mutations
	###
	
	foreach my $mut (@muts)
	{
		#insertion
		if (length $mut->{ref_seq} == 0)
		{			
			$mut->{type} = 'INS';
			
			## unused fields
			delete $mut->{ref_seq};
		}
		#deletion
		elsif (length $mut->{new_seq} == 0)
		{
			$mut->{type} = 'DEL';
			$mut->{size} = $mut->{end} - $mut->{start} + 1;
			
			## unused fields
			delete $mut->{new_seq};
			delete $mut->{ref_seq};
		}
		#block substitution
		elsif ((length $mut->{ref_seq} > 1) || (length $mut->{new_seq} > 1))
		{
			$mut->{type} = 'SUB';
			$mut->{size} = length($mut->{ref_seq});
			delete $mut->{ref_seq};
		}
		#snp
		else
		{
			delete $mut->{ref_seq};
			$mut->{type} = 'SNP';
		}
		
		## we don't need these fields
		delete $mut->{frequency} if ($mut->{frequency} == 1);
		delete $mut->{start};		
		delete $mut->{end};
		delete $mut->{insert_start};
		delete $mut->{insert_end};
		
		$gd->add($mut);
	}
	
	
	## PROBLEM: We can't apply the coverage cutoff until AFTER we count errors
	##   (because only then do we have the distribution to fit)
	##   but we have to choose which junctions we believe BEFORE counting
	##   (because we put their split alignments in the BAM file)
	## Ideally we would do this after step 7, then remove the offending read pieces from the BAM file
	## before proceeding to SNP calling.
	## this could be done by reserving these pieces in a separate SAM file
	## then merging them later? But full matches would also have to be kept separate...
	##

	## Remove remaining junctions that we didn't pair up with anything that are below a coverage cutoff.
	@jc = $gd->filter_used_as_evidence($gd->list('JC'));	
	foreach my $item (@jc)
	{		
		my $coverage_cutoff_1 = $settings->{unique_coverage}->{$item->{side_1_seq_id}}->{junction_coverage_cutoff};
		my $coverage_cutoff_2 = $settings->{unique_coverage}->{$item->{side_2_seq_id}}->{junction_coverage_cutoff};
		
		if ( (!defined $coverage_cutoff_1 || ($item->{total_reads} < $coverage_cutoff_1) ) 
		  && (!defined $coverage_cutoff_2 || ($item->{total_reads} < $coverage_cutoff_2) ) )
		{
			Breseq::GenomeDiff::add_reject_reason($item, "COV");
		}
	}
	
}


return 1;