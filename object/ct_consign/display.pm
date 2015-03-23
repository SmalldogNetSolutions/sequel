package sequel::object::ct_consign::display;

use strict;
use Carp;

sub main {
	my $s = shift;

	return unless($s->check_in_id());

	$s->add_action(function => 'pos',
		icon => 'shopping-cart',
		title => 'Point of Sale');

	$s->add_action(function => 'list');
	$s->add_action(function => 'edit');
	$s->add_action(function => 'addnote',
		icon => 'comments',
		title => 'Add Note',
		params => "ct_consign_id=$s->{in}{ct_consign_id}");

	#$s->add_action(function => 'delete');

	my %hash = $s->db_q("
		SELECT *
		FROM ct_consign
		WHERE ct_consign_id=?
		",'hash',
		v => [ $s->{in}{ct_consign_id} ]);

	$hash{cc_account_id} = $s->db_q("SELECT gl_account('cc')",'scalar');

	$hash{cash_balance} = $s->db_q("
		SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric
		FROM postings p
			JOIN transactions t ON p.trans_id=t.trans_id
				AND t.post_date IS NOT NULL
		WHERE p.ref='vendor'
		AND p.ref_id=?
		AND p.account_id=gl_account('cc')
		",'scalar',
		v => [ $hash{vendor_id} ])
		if ($hash{vendor_id});
	
	$s->add_action(function => 'list',
		object => 'gl',
		icon => 'list-alt',
		title => 'Cash Transactions',
		params => "account_id=$hash{cc_account_id}&ref=vendor&ref_id=$hash{vendor_id}&process=1")
		if ($hash{vendor_id});

	$s->add_action(function => 'pay',
		subroutine => 'checks',
		icon => 'exclamation-sign',
		title => 'Open Checks',
		params => "ct_consign_id=$hash{ct_consign_id}")
		if ($hash{vendor_id});

#	if ($hash{vendor_id} && $hash{cash_balance} ne '0.00') {
#		$s->add_action(function => 'pay',
#			params => "ct_consign_id=$hash{ct_consign_id}");
#	}

	$hash{credit_balance} = $s->db_q("
		SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric
		FROM postings p
			JOIN transactions t ON p.trans_id=t.trans_id
				AND t.post_date IS NOT NULL
		WHERE p.ref='customer'
		AND p.ref_id=?
		AND p.account_id=gl_account('cc')
		",'scalar',
		v => [ $hash{customer_id} ])
		if ($hash{customer_id});

	$hash{total_balance} = sprintf "%.2f", $hash{cash_balance}+$hash{credit_balance}
		if ($hash{customer_id} && $hash{vendor_id});

	$s->add_action(function => 'list',
		object => 'gl',
		icon => 'list-alt',
		title => 'Credit Transactions',
		params => "account_id=$hash{cc_account_id}&ref=customer&ref_id=$hash{customer_id}&process=1")
		if ($hash{customer_id});

	@{$hash{logs}} = $s->db_q("
		SELECT *
		FROM logs_v
		WHERE ref='ct_consign'
		AND ref_id=?
		ORDER BY created_ts desc
		",'arrayhash',
		v => [ $hash{ct_consign_id} ]);

	@{$hash{notes}} = $s->db_q("
		SELECT *
		FROM notes_v
		WHERE ref='ct_consign'
		AND ref_id=?
		ORDER BY created_ts desc
		",'arrayhash',
		v => [ $hash{ct_consign_id} ]);

	$s->tt('ct_consign/display.tt', { s => $s, hash => \%hash });

#	$s->{content} .= $s->dump(\%hash);
}

1;
