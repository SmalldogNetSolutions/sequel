package sequel::object::ct_consign::pay;

use strict;
use Carp;

sub main {
	my $s = shift;

	if ($s->{in}{ct_consign_id}) {
		$s->add_action(function => 'display');

		my %hash = $s->db_q("
			SELECT *
			FROM ct_consign
			WHERE ct_consign_id=?
			",'hash',
			v => [ $s->{in}{ct_consign_id} ]);

		unless($hash{vendor_id}) {
			$s->alert("No vendor_id assigned.  Can not pay cash out");
			return;
		}

		$hash{cash_balance} = $s->db_q("
			SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric
			FROM postings p
			WHERE p.ref='vendor'
			AND p.ref_id=?
			AND p.account_id=gl_account('cc')
			",'scalar',
			v => [ $hash{vendor_id} ]);

		unless($s->{in}{confirm}) {
			$s->confirm("Create payment voucher for $hash{cash_balance} to $hash{name}?");
			return;
		}

		$s->{dbh}->begin_work;

		# hack, on term and funit...but whatever
		my $voucher_id = $s->db_insert('vouchers',{
			vendor_id => $hash{vendor_id},
			term_id => 1000,
			funit_id => 1000,
			voucher_date => $s->{datetime}{ymd},
			ref_id => "$hash{vendor_id}-$s->{datetime}{ymd}",
			voucher_status => 'new',
			},'voucher_id');
		
		$s->db_insert('voucher_items',{
			voucher_id => $voucher_id,
			description => "Consignment",
			ref => 'vendor',
			ref_id => $hash{vendor_id},
			account_id => "_raw:gl_account('cc')",
			qty => 1,
			unit_cost => $hash{cash_balance},
			});

		$s->db_q("SELECT post_voucher(?,?)",undef, v => [ $voucher_id, $s->{employee_id} ]);

		$s->{dbh}->commit;

		$s->notify("Voucher $voucher_id created");

		$s->redirect();
		return;
	} else {
		$s->add_action(function => 'list');

		unless($s->{in}{amount} && $s->{in}{pay_date}) {
			$s->tt('ct_consign/pay.tt', { s => $s });
			return;
		}

		# include in this list any credit balances that we need to deal with moving over
		my @list = $s->db_q("
			SELECT x.vendor_id, x.name, x.amount+COALESCE(y.amount,0) as amount,
				y.amount as credit_balance, y.customer_id
			FROM (
				SELECT v.vendor_id, v.name, sum(p.credit-p.debit) as amount
				FROM postings p
					JOIN transactions t ON p.trans_id=t.trans_id
						AND t.post_date < date(?)
					JOIN vendors_v v ON p.ref_id=v.vendor_id
				WHERE p.ref='vendor'
				AND p.account_id=gl_account('cc')
				GROUP BY 1,2
				) x
				LEFT JOIN (
					SELECT c.vendor_id, c.customer_id, sum(p.credit-p.debit) as amount
					FROM ct_consign c
						JOIN postings p ON p.ref='customer' 
							AND p.ref_id=c.customer_id
							AND p.account_id=gl_account('cc')
						JOIN transactions t ON p.trans_id=t.trans_id
							AND t.post_date < date(?)
					WHERE c.vendor_id IS NOT NULL
					AND c.customer_id IS NOT NULL
					GROUP BY 1,2
					HAVING sum(p.credit-p.debit)<0
					) y ON x.vendor_id=y.vendor_id
			WHERE x.amount+COALESCE(y.amount,0)>?
			ORDER BY name
			",'arrayhash',
			v => [ $s->{in}{pay_date}, $s->{in}{pay_date}, $s->{in}{amount} ]);

		my %ap = $s->db_q("
			SELECT v.vendor_id, sum(p.credit-p.debit) as amount
			FROM postings p
				JOIN transactions t ON p.trans_id=t.trans_id
					AND t.post_date IS NOT NULL
				JOIN vendors_v v ON p.ref_id=v.vendor_id
			WHERE p.ref='vendor'
			AND p.account_id=gl_account('ap')
			GROUP BY 1
			HAVING sum(p.credit-p.debit)!=0
			",'keyval');

		if ($s->{in}{process}) {
			#$s->{content} .= $s->dump(\@list); return;
			my $voucher_date = $s->db_q("
				SELECT (date(?)-interval '1 day')
				",'scalar',
				v => [ $s->{in}{pay_date} ]);

			$s->{dbh}->begin_work;

			foreach my $ref (@list) {
				# hack, on term and funit...but whatever
				my $voucher_id = $s->db_insert('vouchers',{
					vendor_id => $ref->{vendor_id},
					term_id => 1000,
					funit_id => 1000,
					voucher_date => $voucher_date,
					ref_num => "$ref->{vendor_id}-$s->{datetime}{ymd}",
					voucher_status => 'new',
					},'voucher_id');
			
				if ($ref->{credit_balance}) {
					my $total = sprintf "%.2f", $ref->{amount}-$ref->{credit_balance};
					$s->db_insert('voucher_items',{
						voucher_id => $voucher_id,
						description => "Consignment",
						ref => 'vendor',
						ref_id => $ref->{vendor_id},
						account_id => "_raw:gl_account('cc')",
						qty => 1,
						unit_cost => $total,
						});
					$s->db_insert('voucher_items',{
						voucher_id => $voucher_id,
						description => "Consignment - Credit Transfer",
						ref => 'customer',
						ref_id => $ref->{customer_id},
						account_id => "_raw:gl_account('cc')",
						qty => 1,
						unit_cost => $ref->{credit_balance},
						});
				} else {
					$s->db_insert('voucher_items',{
						voucher_id => $voucher_id,
						description => "Consignment",
						ref => 'vendor',
						ref_id => $ref->{vendor_id},
						account_id => "_raw:gl_account('cc')",
						qty => 1,
						unit_cost => $ref->{amount},
						});
				}
	
				$s->db_q("SELECT post_voucher(?,?)",undef, v => [ $voucher_id, $s->{employee_id} ]);
			}

			$s->{dbh}->commit;

			$s->notify("Vouchers created");

			$s->redirect(function => 'list',
				object => 'voucher',
				params => "b=posted");
			return;
		}

		my %hash = $s->sum(\@list,{ amount => 2, });
		#$s->{content} .= $s->dump(\%ap);
		$s->tt('ct_consign/pay_review.tt', { s => $s, list => \@list, hash => \%hash, ap => \%ap });
	}
}

sub checks {
	my $s = shift;

	return unless($s->check_in_id());

	my %hash = $s->db_q("
		SELECT *
		FROM ct_consign
		WHERE ct_consign_id=?
		",'hash',
		v => [ $s->{in}{ct_consign_id} ]);

	$s->add_action(function => 'display');

	unless($hash{vendor_id}) {
		$s->alert("Not a cash consignment customer");
		return;
	}

	my @list = $s->db_q("
		SELECT v.*,
			(SELECT array_to_string(array_agg(t.trans_id),',')
			FROM transactions t
			WHERE t.ref='check'
			AND t.ref_id=v.check_id) as trans_id
		FROM checks_v v
		WHERE v.vendor_id=?
		AND v.cleared IS NULL
		ORDER BY check_date, check_id desc
		",'arrayhash',
		v => [ $hash{vendor_id} ]);

	#$s->{content} .= $s->dump(\@list);

	$s->tt('ct_consign/checks.tt', { s => $s, list => \@list, });
}

sub cancel {
	my $s = shift;

	unless($s->{in}{ct_consign}) {
		if ($s->{in}{check_num}) {
			my %tmp = $s->db_q("
				SELECT v.*,
					(SELECT array_to_string(array_agg(t.trans_id),',')
					FROM transactions t
					WHERE t.ref='check'
					AND t.ref_id=v.check_id) as trans_id
				FROM checks_v v
				WHERE v.check_num=?
				",'hash',
				v => [ $s->{in}{check_num} ]);

			if ($tmp{check_id}) {
				$s->tt('ct_consign/cancel_check_review.tt', { s => $s, hash => \%tmp });
				#$s->{content} .= $s->dump(\%tmp);
				return;
			} else {
				$s->alert("Check not found, or check has already been canceled");
			}
		}

		unless($s->{in}{check_id}) {
			$s->tt('ct_consign/cancel_check.tt', { s => $s, });
			return;
		}
	}

	return unless($s->check_in_id('check_id'));

	my %hash = $s->db_q("
		SELECT v.*,
			(SELECT array_to_string(array_agg(t.trans_id),',')
			FROM transactions t
			WHERE t.ref='check'
			AND t.ref_id=v.check_id) as trans_id
		FROM checks_v v
		WHERE v.check_id=?
		",'hash',
		v => [ $s->{in}{check_id} ]);

#	$s->{content} .= $s->dump(\%hash); return;

	if ($hash{cleared}) {
		$s->alert("Sorry, that check has cleared, you can not void it");
		return;
	}

	unless($hash{trans_id}) {
		$s->alert("Check is not posted, can not void it");
		return;
	}

	my %trans = $s->db_q("
		SELECT v.*, p.close_date,
			CASE WHEN v.post_date <= p.close_date THEN TRUE ELSE FALSE END as closed
		FROM transactions_v_summary v
			JOIN sitedata p ON p.id=1
		WHERE v.trans_id=?
		",'hash',
		v => [ $hash{trans_id} ]);

	$s->{dbh}->begin_work;

	my %tmp = $s->db_q("
		SELECT *
		FROM transactions
		WHERE trans_id=?
		",'hash',
		v => [ $hash{trans_id} ]);

	my $trans_id = $s->db_insert("transactions",{
		funit_id => $tmp{funit_id},
		employee_id => $s->{employee_id},
		ref => 'check',
		ref_id => $hash{check_id},
		description => 'Void and cancel check',
		#location_id => $tmp{location_id},
		#ref_date => $hash{post_date},
		},'trans_id');

	$s->db_q("SELECT gl_debit(?,'vendor',?,?,NULL,?,NULL)",undef,
		v => [ $trans_id, $hash{vendor_id}, $hash{account_id}, $hash{amount} ]);

	$s->db_q("SELECT gl_credit(?,'vendor',?,gl_account('cogs'),NULL,?,?)",undef,
		v => [ $trans_id, $hash{vendor_id}, $hash{amount}, "void check" ]);

	$s->db_q("SELECT post_transaction(?)",undef, v => [ $trans_id ]);

	$s->db_q("UPDATE checks SET 
			closed=TRUE,
			cleared=NULL,
			void_ts=tz_now(),
			void_employee_id=?,
			void_check_num=check_num,
			check_num=NULL
		WHERE check_id=?
		",undef, v => [ $s->{employee_id}, $hash{check_id} ]);

	$s->log('check',$hash{check_id},"Check voided and canceled");

	$s->{dbh}->commit;

	$s->notify("Check Voided and Canceled");

	if ($s->{in}{ct_consign_id}) {
		$s->redirect(function => 'pay',
			subroutine => 'checks',
			params => "ct_consign_id=$s->{in}{ct_consign_id}");
	} else {
		$s->redirect(function => 'pay',
			subroutine => 'cancel');
	}
}

1;
