package sequel::object::ct_consign;

use strict;
use Carp;

sub config {
	my $s = shift;

	return {
		id => 'ct_consign_id',
		functions => {
			list => 'List',
			create => 'Create',
			edit => 'Edit',
			display => 'Display',
			pos => 'Sale',
			pay => 'Pay Cash Balance',
			delete => 'Delete',
			addnote => 'Add Note',
			sales => 'Sales Totals',
			},
		};
}

1;
