package sequel::object::ct_consign::delete;

use strict;
use Carp;

sub main {
	my $s = shift;

	return unless($s->check_in_id());
}

1;
