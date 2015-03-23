package sequel::object::ct_consign::edit;

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
		icon => 'usd',
		params => "ct_consign_id=$hash{ct_consign_id}")
		if ($hash{vendor_id} && $hash{cash});

	$s->add_action(function => 'edit',
		subroutine => 'addcredit',
		title => 'Add Credit',
		icon => 'credit_card',
		params => "ct_consign_id=$hash{ct_consign_id}")
		if ($hash{customer_id} && !$hash{cash});

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

		if (defined($update{cash})) {
			if ($hash{cash} ne $update{cash}) {
				# we changed from cash to credit or something, so move our balance over
				# what was the difference in consign fee?
				$hash{diff_percent} = sprintf "%.4f", $update{consign_percent}-$hash{consign_percent};
				if ($update{cash}) {
					if ($hash{credit_balance} ne '0.00' && $hash{credit_balance}) {
						$hash{old_balance} = $hash{credit_balance};
						$hash{old_ref} = 'customer';
						$hash{old_ref_id} = $hash{customer_id};
						$hash{new_ref} = 'vendor';
						$hash{new_ref_id} = $update{vendor_id} || $hash{vendor_id};
					}
				} else {
					if ($hash{cash_balance} ne '0.00' && $hash{cash_balance}) {
						$hash{old_balance} = $hash{cash_balance};
						$hash{old_ref} = 'vendor';
						$hash{old_ref_id} = $hash{vendor_id};
						$hash{new_ref} = 'customer';
						$hash{new_ref_id} = $update{customer_id} || $hash{customer_id};
					}
				}
	
				if ($hash{new_ref}) {
					if ($hash{diff_percent} > 0) {
						$hash{new_balance} = sprintf "%.2f", ($hash{old_balance}*($hash{diff_percent}+1.0));
					} else {
						$hash{new_balance} = sprintf "%.2f", ($hash{old_balance}/(abs($hash{diff_percent})+1.0));
					}
	
					$hash{balance_diff} = sprintf "%.2f", $hash{new_balance}-$hash{old_balance};
					croak "Missing new_ref_id" unless($hash{new_ref_id});
	
					#croak "error: ".Data::Dumper->Dump([\%hash]);
					# create a transaction that moves the balace over and write a log message
					my $trans_id = $s->db_insert('transactions',{
						funit_id => 1000,
						ref => 'ct_consign',
						ref_id => $hash{ct_consign_id},
						description => 'Transfer account balance'
						},'trans_id');
	
					$s->db_q("SELECT gl_debit(?,?,?,gl_account('cc'),NULL,?,NULL)",undef,
						v => [ $trans_id, $hash{old_ref}, $hash{old_ref_id}, $hash{old_balance} ]);
	
					$s->db_q("SELECT gl_credit(?,?,?,gl_account('cc'),NULL,?,NULL)",undef,
						v => [ $trans_id, $hash{new_ref}, $hash{new_ref_id}, $hash{new_balance} ]);
	
					$s->db_q("SELECT gl_debit(?,NULL,NULL,gl_account('cogs'),NULL,?,NULL)",undef,
						v => [ $trans_id, $hash{balance_diff} ])
						if ($hash{balance_diff} ne '0.00');
	
					$s->db_q("SELECT post_transaction(?)",undef, v => [ $trans_id ]);
	
					if ($update{cash}) {
						$s->log('ct_consign',$hash{ct_consign_id},"Converted credit balance of $hash{old_balance} to cash balance of $hash{new_balance} (change of $hash{balance_diff})");
					} else {
						$s->log('ct_consign',$hash{ct_consign_id},"Converted cash balance of $hash{old_balance} to credit balance of $hash{new_balance} (change of $hash{balance_diff})");
					}
				}
			}
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
