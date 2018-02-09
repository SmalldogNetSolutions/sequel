package sequel::object::ct_consign::list;

use strict;
use Carp;

sub main {
	my $s = shift;

	my @locations = $s->db_q("
		SELECT location_id, name
		FROM locations
		WHERE sales IS TRUE
		AND till_account_id IS NOT NULL
		ORDER BY name
		",'arrayhash');

	if (scalar @locations == 1) {
			$s->add_action(function => 'pos',
				subroutine => 'create',
				icon => 'plus',
				title => "New Sale",
				params => "location_id=$locations[0]{location_id}");
	}

	foreach my $ref (@locations) {
		$s->add_action(function => 'pos',
			icon => 'shopping-cart',
			title => "$ref->{name} POS",
			params => "location_id=$ref->{location_id}");
	}

#	$s->add_action(function => 'list', title => 'List Active',
#		params => "showlist=1");

#	$s->add_action(function => 'list', title => 'List All',
#		params => "showlist=1&showall=1");

	if ($s->{in}{showlist}) {
	
		$s->add_action(function => 'list', title => 'Search');

		my $where = ($s->{in}{showall}) ? '' : 'WHERE v.inactive_ts IS NULL';

		my @list = $s->db_q("
			SELECT v.*, vv.balance as cash_balance,
				cc.balance as credit_balance,
				(COALESCE(vv.balance,0)+COALESCE(cc.balance,0))::numeric as total_balance
			FROM ct_consign v
				LEFT JOIN (
					SELECT p.ref_id as vendor_id, COALESCE(sum(p.credit-p.debit),0.00)::numeric as balance
					FROM postings p
						JOIN transactions t ON p.trans_id=t.trans_id
							AND t.post_date IS NOT NULL
					WHERE p.ref='vendor'
					AND p.account_id=gl_account('cc')
					GROUP BY 1
					) vv ON v.vendor_id=vv.vendor_id
				LEFT JOIN (
					SELECT p.ref_id as customer_id, COALESCE(sum(p.credit-p.debit),0.00)::numeric as balance
					FROM postings p
						JOIN transactions t ON p.trans_id=t.trans_id
							AND t.post_date IS NOT NULL
					WHERE p.ref='customer'
					AND p.account_id=gl_account('cc')
					GROUP BY 1
					) cc ON v.customer_id=cc.customer_id
			$where
			ORDER BY name
			",'arrayhash');

		#$s->{content} .= $s->dump(\%hash);
	
		$s->tt('ct_consign/list.tt', { s => $s, list => \@list });
		return;
	} else {
	
		$s->add_action(function => 'list', title => 'List Accounts',
			params => "showlist=1&showall=1");

		# do the ajax stuff to show the list
		$s->tt('ct_consign/list_ajax.tt', { s => $s, });
	}

	$s->add_action(function => 'create',
		title => 'New Account');

	$s->add_action(function => 'pay',
		icon => 'usd',
		title => 'Pay Vendors');

	$s->add_action(function => 'pay',
		subroutine => 'cancel',
		icon => 'exclamation-sign',
		title => 'Cancel Check');

	if ($s->check_permission($s->{object},'sales')) {
		my @sales = $s->db_q("
			SELECT l.name as location_name, sum(v.subtotal) as subtotal,
				sum(v.total) as total, sum(v.tax) as tax
			FROM (
				SELECT o.location_id, o.order_id
				FROM orders o
				WHERE o.order_type='order'
				AND o.order_status='closed'
				AND date(o.close_ts)=date(tz_now())
				) x
				JOIN orders_v_summary v ON x.order_id=v.order_id
				JOIN locations l ON x.location_id=l.location_id
			GROUP BY 1
			ORDER BY 1
			",'arrayhash');
		
		my @payments = $s->db_q("
			SELECT CASE WHEN pm.store_credit IS TRUE OR pm.gift_card IS TRUE THEN 'Credit/Gift'
				ELSE 'Cash/Check/CC' END as type,
				sum(p.amount) as total
			FROM customer_payments p
				JOIN payment_methods pm ON p.payment_method_id=pm.payment_method_id
			WHERE date(p.process_ts)=date(tz_now())
			GROUP BY 1
			ORDER BY 1
			",'arrayhash');
		
		my %total = $s->sum(\@sales,{ subtotal => 2, total => 2, tax => 2, });
		my %ptotal = $s->sum(\@payments,{ total => 2 });

		$s->tt('ct_consign/sales.tt', { s => $s, list => \@sales, pay => \@payments, phash => \%ptotal,
			hash => \%total });
	}

	my %msg = $s->db_q("
		SELECT key, value
		FROM systemdata
		WHERE key='cherryt_msg'
		",'keyval');

	if ($s->{in}{f} eq 'savemsg') {
		if (defined($msg{cherryt_msg})) {
			$s->db_q("UPDATE systemdata SET value=?
				WHERE key='cherryt_msg'
				",undef,
				v => [ $s->{in}{msg} ]);
		} else {
			$s->db_insert('systemdata',{
				key => 'cherryt_msg',
				value => $s->{in}{msg},
				});
		}

		$msg{cherryt_msg} = $s->{in}{msg};
	}

	$s->tt('ct_consign/message.tt', { s => $s, hash => \%msg });
}

sub search {
	my $s = shift;

	my @list = $s->db_q("
		SELECT ct_consign_id, name
		FROM ct_consign
		WHERE name~*?
		ORDER BY name
		",'arrayhash',
		v => [ $s->{in}{q} ]);

	$s->{content_type} = 'application/json';
	$s->{content} = '[';
	my @kv;
	foreach my $ref (@list) {
		$ref->{name} =~ s/"//g;
		push @kv, qq({ "url" : "$s->{uo}/display?ct_consign_id=$ref->{ct_consign_id}", "name" : "[$ref->{ct_consign_id}] $ref->{name}" });
	}
	$s->{content} .= (join ',', @kv);
	$s->{content} .= ']';
}

1;
