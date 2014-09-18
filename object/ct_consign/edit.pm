package cherryt::object::ct_consign::edit;

use strict;
use Carp;

sub main {
	my $s = shift;

	return unless($s->check_in_id());

	$s->add_action(function => 'display');

	my %hash = $s->db_q("
		SELECT *
		FROM ct_consign
		WHERE ct_consign_id=?
		",'hash',
		v => [ $s->{in}{ct_consign_id} ]);

	$hash{cash_balance} = $s->db_q("
		SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric
		FROM postings p
		WHERE p.ref='vendor'
		AND p.ref_id=?
		AND p.account_id=gl_account('cc')
		",'scalar',
		v => [ $hash{vendor_id} ])
		if ($hash{vendor_id});

	$s->add_action(function => 'edit',
		subroutine => 'addcash',
		title => 'Add Cash',
		params => "ct_consign_id=$hash{ct_consign_id}")
		if ($hash{vendor_id});

	$s->add_action(function => 'edit',
		subroutine => 'addcredit',
		title => 'Add Credit',
		params => "ct_consign_id=$hash{ct_consign_id}")
		if ($hash{customer_id});

	$hash{credit_balance} = $s->db_q("
		SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric
		FROM postings p
		WHERE p.ref='customer'
		AND p.ref_id=?
		AND p.account_id=gl_account('cc')
		",'scalar',
		v => [ $hash{customer_id} ])
		if ($hash{customer_id});

	if ($s->{in}{process}) {
		my %update;
		$s->{dbh}->begin_work;

		foreach my $k (qw(name cash consign_percent consign_fee)) {
			if ($hash{$k} ne $s->{in}{$k}) {
				$update{$k} = $s->{in}{$k};
				$s->log('ct_consign',$hash{ct_consign_id},"$k changed from $hash{$k} to $s->{in}{$k}");
			}
		}

		if (defined($update{cash})) {
			if ($update{cash} && !$hash{vendor_id}) {
				# we need to create a vendor_id
				my $profile_id = $s->db_insert('profiles',{
					individual => 0,
					organization => $hash{name},
					},'profile_id');

				my $vendor_id = $s->db_insert('vendors',{
					account => $hash{ct_consign_id},
					profile_id => $profile_id,
					employee_id => $s->{employee_id},
					},'vendor_id');

				$update{vendor_id} = $vendor_id;
			} elsif (!$update{cash} && !$hash{customer_id}) {
				# create a customer account
				my $customer_id = $s->db_insert('customers',{
					email_phone => $hash{ct_consign_id},
					company => $hash{name},
					individual => 0,
					},'customer_id');

				$update{customer_id} = $customer_id;
			}
		}

		if (keys %update) {
			if ($update{consign_fee}) {
				$update{consign_percent} = 0;
			} else {
				$update{consign_fee} = '';
			}
			$s->db_update_key('ct_consign','ct_consign_id',$hash{ct_consign_id},\%update);
		}

		$s->{dbh}->commit;

		$s->redirect();
		return;
	}

	$s->tt('ct_consign/edit.tt', { s => $s, hash => \%hash });
}

sub addcash {
	my $s = shift;

	return unless($s->check_in_id());

	$s->add_action(function => 'display');

	my %hash = $s->db_q("
		SELECT *
		FROM ct_consign
		WHERE ct_consign_id=?
		",'hash',
		v => [ $s->{in}{ct_consign_id} ]);

	if ($s->{in}{process}) {
		$s->{dbh}->begin_work;

		my $trans_id = $s->db_insert('transactions',{
			funit_id => 1000,
			employee_id => $s->{employee_id},
			ref => 'vendor',
			ref_id => $hash{vendor_id},
			description => 'Manual Cash Adjustment',
			},'trans_id');

		$s->db_q("SELECT gl_credit(?,'vendor',?,gl_account('cc'),NULL,?,NULL)",undef,
			v => [ $trans_id, $hash{vendor_id}, $s->{in}{amount} ]);

		$s->db_q("SELECT gl_debit(?,'vendor',?,gl_account('cogs'),NULL,?,NULL)",undef,
			v => [ $trans_id, $hash{vendor_id}, $s->{in}{amount} ]);

		$s->db_q("SELECT post_transaction(?)",undef, v => [ $trans_id ]);

		$s->{dbh}->commit;

		$s->notify("Cash Balance Modified");

		$s->redirect(function => 'display');
		return;
	}

	$hash{cash_balance} = $s->db_q("
		SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric
		FROM postings p
		WHERE p.ref='vendor'
		AND p.ref_id=?
		AND p.account_id=gl_account('cc')
		",'scalar',
		v => [ $hash{vendor_id} ])
		if ($hash{vendor_id});

	$s->tt('ct_consign/add_cash.tt', { s => $s, hash => \%hash });
}

sub addcredit {
	my $s = shift;

	return unless($s->check_in_id());

	$s->add_action(function => 'display');

	my %hash = $s->db_q("
		SELECT *
		FROM ct_consign
		WHERE ct_consign_id=?
		",'hash',
		v => [ $s->{in}{ct_consign_id} ]);

	my %hash = $s->db_q("
		SELECT *
		FROM ct_consign
		WHERE ct_consign_id=?
		",'hash',
		v => [ $s->{in}{ct_consign_id} ]);

	if ($s->{in}{process}) {
		$s->{dbh}->begin_work;

		my $trans_id = $s->db_insert('transactions',{
			funit_id => 1000,
			employee_id => $s->{employee_id},
			ref => 'customer',
			ref_id => $hash{customer_id},
			description => 'Manual Credit Adjustment',
			},'trans_id');

		$s->db_q("SELECT gl_credit(?,'customer',?,gl_account('cc'),NULL,?,NULL)",undef,
			v => [ $trans_id, $hash{customer_id}, $s->{in}{amount} ]);

		$s->db_q("SELECT gl_debit(?,'customer',?,gl_account('cogs'),NULL,?,NULL)",undef,
			v => [ $trans_id, $hash{customer_id}, $s->{in}{amount} ]);

		$s->db_q("SELECT post_transaction(?)",undef, v => [ $trans_id ]);

		$s->{dbh}->commit;

		$s->notify("Credit Balance Modified");

		$s->redirect(function => 'display');
		return;
	}

	$hash{credit_balance} = $s->db_q("
		SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric
		FROM postings p
		WHERE p.ref='customer'
		AND p.ref_id=?
		AND p.account_id=gl_account('cc')
		",'scalar',
		v => [ $hash{customer_id} ])
		if ($hash{customer_id});

	$s->tt('ct_consign/add_credit.tt', { s => $s, hash => \%hash });
}

1;
