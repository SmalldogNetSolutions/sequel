package sequel::object::ct_consign::pos;

use strict;
use Carp;
use erp::object::order;
use erp::object::check::void;
use erp::object::voucher::unpost;

sub main {
	my $s = shift;

	$s->add_action(function => 'list',
		title => 'Customers');

	unless($s->{in}{location_id}) {
		my @locations = $s->db_q("
			SELECT location_id, name
			FROM locations
			WHERE sales IS TRUE
			AND till_account_id IS NOT NULL
			ORDER BY name
			",'arrayhash');

		$s->tt('ct_consign/pos_location.tt', { s => $s, list => \@locations });
		return;
	}

	#$s->add_action(function => 'pos',
	#	title => 'Locations');

	$s->add_action(function => 'pos',
		subroutine => 'create',
		icon => 'plus',
		title => 'New Sale',
		params => "location_id=$s->{in}{location_id}");

	$s->add_action(function => 'pos',
		subroutine => 'today',
		icon => 'stats',
		title => 'Sales Today',
		params => "location_id=$s->{in}{location_id}");

	my %hash = $s->db_q("
		SELECT *
		FROM locations_v
		WHERE location_id=?
		",'hash',
		v => [ $s->{in}{location_id} ]);

	my @list = $s->db_q("
		SELECT v.*, (
			SELECT total
			FROM orders_v_summary
			WHERE order_id=v.order_id
			) as total
		FROM orders_v v
		WHERE v.order_type='order'
		AND v.order_status IN ('pos')
		AND v.location_id=?
		ORDER BY created_ts
		",'arrayhash',
		v => [ $hash{location_id} ]);

	$s->tt('ct_consign/pos_list.tt', { s => $s, list => \@list, hash => \%hash });
}

sub today {
	my $s = shift;

	return unless($s->check_in_id('location_id'));

	$s->add_action(function => 'list',
		title => 'Customers');

	$s->add_action(function => 'pos',
		subroutine => 'create',
		title => 'New Sale',
		params => "location_id=$s->{in}{location_id}");

	$s->add_action(function => 'pos',
		title => 'Open Sales',
		params => "location_id=$s->{in}{location_id}");

	my @list = $s->db_q("
		SELECT v.*, (
			SELECT total
			FROM orders_v_summary
			WHERE order_id=v.order_id
			) as total
		FROM orders_v v
		WHERE v.location_id=?
		AND date(v.order_ts)=date(now())
		AND v.order_type='order'
		AND v.order_status='closed'
		ORDER BY created_ts desc
		",'arrayhash',
		v => [ $s->{in}{location_id} ]);

#	$s->{content} .= $s->dump(\@list);

	$s->tt('ct_consign/pos_today.tt', { s => $s, list => \@list });
}

sub create {
	my $s = shift;

	return unless($s->check_in_id('location_id'));

	my $customer_id = $s->db_q("
		SELECT customer_id
		FROM customers
		WHERE cash IS TRUE
		",'scalar');

	unless($customer_id) {
		$s->alert("Sorry, no cash customer found");
		return;
	}

	my @funits = $s->db_q("
		SELECT funit_id, name
		FROM funits
		ORDER BY name
		",'arrayhash');

	if (scalar @funits == 1) {
		$s->{in}{funit_id} = $funits[0]{funit_id};
	} else {
		$s->alert("Sorry, either no funits or more than 1");
		return;
	}

	return unless($s->check_in_id('funit_id'));

	my %loc = $s->db_q("
		SELECT *
		FROM locations
		WHERE location_id=?
		",'hash',
		v => [ $s->{in}{location_id} ]);

	my $order_id = $s->db_insert('orders',{
		order_type => 'order',
		order_status => 'pos',
		customer_id => $customer_id,
		employee_id => $s->{employee_id},
		funit_id => $s->{in}{funit_id},
		location_id => $s->{in}{location_id},
		},'order_id');

	$s->db_insert('shipping',{
		order_id => $order_id,
		cost => 0,
		state => $loc{state},
		zipcode => $loc{zipcode},
		});

	$s->redirect(function => 'pos',
		subroutine => 'display',
		params => "order_id=$order_id");
}

sub pay {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	$s->add_action(function => 'pos',
		subroutine => 'display',
		icon => 'home',
		title => 'Display',
		params => "order_id=$s->{in}{order_id}");

	my %order = $s->db_q("
		SELECT o.order_id, c.customer_id, c.cash
		FROM orders o
			JOIN customers c ON o.customer_id=c.customer_id
		WHERE o.order_id=?
		",'hash',
		v => [ $s->{in}{order_id} ]);

	my %hash = erp::object::order::load($s->{o},$s);

	$hash{balance} = $s->db_q("
		SELECT (?-COALESCE(sum(p.amount),0))::numeric(10,2)
		FROM orders o
			LEFT JOIN order_payments p ON o.order_id=p.order_id
		WHERE o.order_id=?
		",'scalar',
		v => [ $hash{summary}{total}, $s->{in}{order_id} ]);

	my %pm = $s->db_q("
		SELECT *
		FROM payment_methods
		WHERE payment_method_id=?
		",'hash',
		v => [ $s->{in}{payment_method_id} ]);

	unless($s->{in}{payment_method_id}) {
		$s->alert("Please choose a payment method") if ($s->{in}{process});

		my @list = $s->db_q("
			SELECT v.*
			FROM payment_methods v
			WHERE v.payment_method_id IN (
				SELECT pg.payment_method_id
				FROM employee_groups eg
					JOIN payment_method_groups pg ON eg.group_id=pg.group_id
				WHERE eg.employee_id=?
				GROUP BY 1
				)
			ORDER BY name
			",'arrayhash',
			v => [ $s->{employee_id} ]);

		#$s->tt('ct_consign/pay_choose.tt', { s => $s, list => \@list });
		$s->tt('ct_consign/pos_payglobal.tt', { s => $s, list => \@list, hash => \%hash, pm => \%pm });
		#$s->{content} .= $s->dump(\@list);
		return;
	}

	if ($pm{store_credit} && !$s->{in}{ct_consign_id}) {
		# try and find id
		$s->{in}{ct_consign_id} = $s->db_q("
			SELECT ct_consign_id
			FROM ct_consign
			WHERE customer_id=?
			",'scalar',
			v => [ $hash{customer_id} ]);

		$s->{in}{process} = 1 if ($s->{in}{ct_consign_id});
	}

	#$s->{content} = $s->dump(\%hash); return;
	if ($s->{in}{process}) {
		$s->alert("Please choose a payment method") unless($s->{in}{payment_method_id});
		$s->{in}{amount} = $hash{balance} if ($pm{store_credit});
		$s->{in}{amount} = $s->{in}{credit_amount} if ($s->{in}{credit_amount});

		$s->alert("Please enter an amount") unless($s->{in}{amount});

		if ($pm{store_credit}) {
			unless($order{cash}) {
				$s->{in}{ct_consign_id} = $s->db_q("
					SELECT ct_consign_id
					FROM ct_consign
					WHERE customer_id=?
					",'scalar',
					v => [ $order{customer_id} ]);
			}

			unless($s->{in}{ct_consign_id}) {
				$s->alert("Please enter store credit customer");
			}
		}

		my %gift_card;

		if ($pm{gift_card}) {
			unless($s->{in}{gift_card_id}) {
				$s->alert("Please enter a gift card number");
			} else {
				my $query = "
					SELECT g.*, CASE WHEN ? > COALESCE(b.balance,0) THEN TRUE ELSE FALSE END as no_balance,
						b.balance
					FROM gift_cards g
						LEFT JOIN (
							SELECT p.ref_id as gift_card_id, sum(p.credit-p.debit) as balance
							FROM postings p
								JOIN transactions t ON p.trans_id=t.trans_id
									AND t.post_date IS NOT NULL
							WHERE p.ref='gift_card'
							AND p.account_id=gl_account('gift')
							GROUP BY 1
							) b ON g.gift_card_id=b.gift_card_id";

				%gift_card = $s->db_q("$query
					WHERE g.gift_card_id=?
					",'hash',
					v => [ $s->{in}{amount}, $s->{in}{gift_card_id} ]) 
						if ($s->{in}{gift_card_id} =~ m/^\d+$/);
	
				unless($gift_card{gift_card_id}) {
					%gift_card = $s->db_q("$query
						WHERE g.legacy_code=?
						",'hash',
						v => [ $s->{in}{amount}, $s->{in}{gift_card_id} ]) ;
				}
		
				unless($gift_card{gift_card_id}) {
					$s->alert("Sorry, gift card not found");
				} elsif ($gift_card{no_balance}) {
					$s->alert("Sorry, that gift card only has a balance of $gift_card{balance}");
				}
				#$s->{content} .= $s->dump(\%gift_card);
			}

		}

		unless($s->{message}) {

			if ($pm{cash}) {
				# what is our balance, then subtract the amount so we can help them make change
				$s->{in}{cash_change} = $s->db_q("
					SELECT ((o.total-COALESCE(sum(p.amount),0)-?)*-1)::numeric(10,2)
					FROM orders_v_summary o
						LEFT JOIN order_payments p ON o.order_id=p.order_id
					WHERE o.order_id=?
					GROUP BY o.total
					",'scalar',
					v => [ $s->{in}{amount}, $s->{in}{order_id} ]);

				if ($s->{in}{cash_change} > 0) {
					$s->{in}{amount} = sprintf "%.2f", $s->{in}{amount}-$s->{in}{cash_change};
				} else {
					$s->{in}{cash_change} = '';
				}
			} elsif ($pm{store_credit}) {
				unless($order{cash}) {
					$s->{in}{ct_consign_id} = $s->db_q("
						SELECT ct_consign_id
						FROM ct_consign
						WHERE customer_id=?
						",'scalar',
						v => [ $order{customer_id} ]);
				}

				if ($s->{in}{ct_consign_id}) {
					# how much credit do they have, and are they a credit customer...
					my %tmp = $s->db_q("
						SELECT x.ct_consign_id, x.customer_id, x.vendor_id,
							x.name, x.cash, x.balance,
							CASE WHEN x.balance < 0 THEN 0
								WHEN x.balance >= x.amount THEN x.amount
								WHEN x.balance < x.amount THEN x.balance
								ELSE NULL END as amount,
							x.balance-x.amount as end_balance
						FROM (
							SELECT c.ct_consign_id, c.customer_id, c.vendor_id,
								c.name, c.cash, ?::numeric as amount,
								COALESCE((
									SELECT sum(p.credit-p.debit)
									FROM postings p
									WHERE p.ref='customer'
									AND p.ref_id=c.customer_id
									AND p.account_id=gl_account('cc')
								),0)+
								COALESCE((
									SELECT sum(p.credit-p.debit)
									FROM ct_consign cc
										JOIN postings p ON p.ref='vendor' AND p.ref_id=cc.vendor_id
											AND p.account_id=gl_account('cc')
									WHERE cc.ct_consign_id=c.ct_consign_id
									AND cc.vendor_id IS NOT NULL
								),0)-
								COALESCE((
									SELECT sum(op.amount)
									FROM order_payments_v op 
									WHERE op.order_id=?
									AND op.store_credit IS TRUE
								),0)::numeric(10,2) as balance
							FROM ct_consign c
							WHERE c.ct_consign_id=?) x
						",'hash',
						v => [ $s->{in}{amount}, $s->{in}{order_id},$s->{in}{ct_consign_id} ]);

					if ($tmp{vendor_id} && !$tmp{customer_id}) {
						$tmp{customer_id} = _make_customer($s,$tmp{vendor_id});
					}

			#		if ($tmp{cash}) {
			#		} else {
					if ($tmp{customer_id}) {
						if ($s->{in}{amount} < 0) {
							1;
						} elsif ($tmp{amount} < $s->{in}{amount}) {
							unless($s->{in}{use_amount}) {
							#	$s->{content} .= $s->dump(\%tmp);
								if ($tmp{cash}) {
									$s->tt('ct_consign/pay_overcredit_cash.tt', { s => $s, hash => \%tmp });
								} else {
									$s->tt('ct_consign/pay_overcredit.tt', { s => $s, hash => \%tmp });
								}
								return;
							}
							$s->{in}{amount} = $s->{in}{use_amount};
						} else {
							$s->{in}{amount} = $tmp{amount};
						}

						$s->db_q("UPDATE orders SET customer_id=?
							WHERE order_id=?
							",undef,
							v => [ $tmp{customer_id}, $s->{in}{order_id} ]);
					} else {
						$s->alert("Sorry, $tmp{name} [$s->{in}{ct_consign_id}] does not have a credit balance");
						return;
						#delete $s->{in}{ct_consign_id};
					}
				}

				unless($s->{in}{ct_consign_id}) {
					croak "Ack, should not get here any more";
					#$s->tt('ct_consign/pay_storecredit.tt', { s => $s, });
					#return;
				}
			}

			#$s->{content} = $s->dump($s->{in}); return;

			if ($pm{store_credit}) {
				my $eid = $s->db_q("
					SELECT order_payment_id
					FROM order_payments
					WHERE order_id=?
					AND payment_method_id=?
					",'scalar',
					v => [ $s->{in}{order_id}, $s->{in}{payment_method_id} ]);
				if ($eid) {
					$s->db_q("UPDATE order_payments SET amount=amount+?
						WHERE order_payment_id=?
						",undef,
						v => [ $s->{in}{amount}, $eid ]);
				} else {
					$s->db_insert('order_payments',{
						order_id => $s->{in}{order_id},
						payment_method_id => $s->{in}{payment_method_id},
						amount => $s->{in}{amount},
						cash_change => $s->{in}{cash_change},
						});
				}
			} elsif ($pm{gift_card}) {
				$s->db_insert('order_payments',{
					order_id => $s->{in}{order_id},
					payment_method_id => $s->{in}{payment_method_id},
					amount => $s->{in}{amount},
					cash_change => $s->{in}{cash_change},
					gift_card_id => $gift_card{gift_card_id},
					});
			} else {
				$s->db_insert('order_payments',{
					order_id => $s->{in}{order_id},
					payment_method_id => $s->{in}{payment_method_id},
					amount => $s->{in}{amount},
					cash_change => $s->{in}{cash_change},
					});
			}

			$s->redirect(function => 'pos',
				subroutine => 'display',
				params => "order_id=$s->{in}{order_id}");

			return;
		}
	}

	my @plist = $s->db_q("
		SELECT v.*
		FROM payment_methods v
		WHERE v.payment_method_id IN (
			SELECT pg.payment_method_id
			FROM employee_groups eg
				JOIN payment_method_groups pg ON eg.group_id=pg.group_id
			WHERE eg.employee_id=?
			GROUP BY 1
			)
		ORDER BY name
		",'arrayhash',
		v => [ $s->{employee_id} ]);

	#$s->tt('ct_consign/pay_choose.tt', { s => $s, list => \@list });
	$s->tt('ct_consign/pos_payglobal.tt', { s => $s, list => \@plist, hash => \%hash, pm => \%pm });
	#$s->{content} .= $s->dump(\@list);
}

sub _make_customer {
	my $s = shift;
	my $vendor_id = shift;

	# lookup this consignment person and create a customer account for them
	my %ctconsign = $s->db_q("
		SELECT *
		FROM ct_consign
		WHERE vendor_id=?
		",'hash',
		v => [ $vendor_id ]);

	unless($ctconsign{customer_id}) {
		$s->{dbh}->begin_work;

		my $profile_id = $s->db_insert('profiles',{
			organization => $ctconsign{name},
			individual => 0,
			},'profile_id');

		my $customer_id = $s->db_insert('customers',{
			profile_id => $profile_id,
			},'customer_id');

		$s->db_q("UPDATE ct_consign SET customer_id=?
			WHERE ct_consign_id=?
			AND customer_id IS NULL
			",undef,
			v => [ $customer_id, $ctconsign{ct_consign_id} ]);
		
		$s->{dbh}->commit;

		return $customer_id;
	} else {
		return $ctconsign{customer_id};
	}
}

sub setcustomer {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	if ($s->{in}{vendor_id} && !$s->{in}{customer_id}) {
		$s->{in}{customer_id} = _make_customer($s,$s->{in}{vendor_id});
	}

	return unless($s->check_in_id('customer_id'));

	my $cash_customer_id = $s->db_q("
		SELECT customer_id
		FROM customers
		WHERE cash IS TRUE
		",'scalar');

	my %exist = $s->db_q("
		SELECT *
		FROM orders
		WHERE order_id=?
		",'hash',
		v => [ $s->{in}{order_id} ]);

	if ($exist{customer_id} ne $s->{in}{customer_id}) {
		if ($exist{customer_id} ne $cash_customer_id) {
			# delete store credit payments
			$s->db_q("DELETE FROM order_payments
				WHERE order_payment_id IN (
					SELECT order_payment_id
					FROM order_payments_v
					WHERE order_id=?
					AND store_credit IS TRUE)
				",undef,
				v => [ $s->{in}{order_id} ]);
		}

		$s->db_q("UPDATE orders SET customer_id=?
			WHERE order_id=?
			",undef,
			v => [ $s->{in}{customer_id}, $s->{in}{order_id} ]);
	}

	$s->redirect(function => 'pos',
		subroutine => 'display',
		params => "order_id=$exist{order_id}");
}

sub close {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	# make order_payments unique across non_till methods
	my @unique = $s->db_q("
		SELECT p.order_id, p.payment_method_id, sum(p.amount) as amount,
			array_to_string(array_agg(p.order_payment_id),',') as ids, count(p.order_payment_id) as idcount
		FROM order_payments p
			JOIN payment_methods pm ON p.payment_method_id=pm.payment_method_id
				AND pm.till_method IS NULL
		WHERE p.order_id=?
		AND p.customer_payment_id IS NULL
		GROUP BY 1,2
		HAVING count(p.order_payment_id) > 1
		",'arrayhash',
		v => [ $s->{in}{order_id} ]);

	#$s->{content} .= $s->dump(\@unique); return;

	if (scalar @unique) {
		$s->{dbh}->begin_work;

		foreach my $ref (@unique) {
			$s->db_q("DELETE FROM order_payments 
				WHERE order_payment_id IN ($ref->{ids})
				AND order_id=?
				AND customer_payment_id IS NULL
				",undef,
				v => [ $s->{in}{order_id} ]);

			$s->db_insert('order_payments',{
				order_id => $s->{in}{order_id},
				payment_method_id => $ref->{payment_method_id},
				amount => $ref->{amount},
				});
		}

		$s->{dbh}->commit;
	}

	#croak "stop";

	# create the payment method, process it, invoice the pos, apply it, create pts, 
	# then close it all
	my %hash = erp::object::order::load($s->{o},$s);

	$s->{dbh}->begin_work;

	my @list = $s->db_q("
		SELECT p.*, pm.payment_processor_id, pm.cash, pm.till_method
		FROM order_payments p
			JOIN payment_methods pm ON p.payment_method_id=pm.payment_method_id
		WHERE p.order_id=?
		AND p.customer_payment_id IS NULL
		",'arrayhash',
		v => [ $hash{order_id} ]);

	my $invoice_id = $s->db_insert('invoices',{
		order_id => $hash{order_id},
		created_ts => '_raw:tz_now()',
		},'invoice_id');

	$s->db_q("UPDATE order_items SET invoice_id=?, account_id=gl_account('sales')
		WHERE order_id=?
		AND invoice_id IS NULL
		",undef,
		v => [ $invoice_id, $hash{order_id} ]);

	$s->db_q("SELECT post_ct_invoice(?)",undef, v => [ $invoice_id ]);

	foreach my $ref (@list) {
		my $customer_payment_id = $s->db_insert('customer_payments',{
			customer_id => $hash{customer_id},
			payment_method_id => $ref->{payment_method_id},
			amount => $ref->{amount},
			payment_processor_id => $ref->{payment_processor_id},
			funit_id => $hash{funit_id},
			gift_card_id => $ref->{gift_card_id},
			},'customer_payment_id');

		$s->db_q("UPDATE customer_payments SET process_ts=now()
			WHERE customer_payment_id=?
			",undef,
			v => [ $customer_payment_id ]);

		# is this customer payment store credit, and is this customer a cash customer
		# if so we need to reverse the balance that we just put into customer credit
		# under the customer reference, and instead put it under the vendor account
		my %tmp = $s->db_q("
			SELECT c.cash, c.vendor_id, t.trans_id, t.post_date, p.post_id, p.ref, p.ref_id
			FROM customer_payments cp
				JOIN transactions t ON cp.customer_payment_id=t.ref_id
					AND t.ref='customer_payment'
				JOIN postings p ON t.trans_id=p.trans_id
					AND p.account_id=gl_account('cc')
				JOIN ct_consign c ON cp.customer_id=c.customer_id
			WHERE cp.customer_payment_id=?
			",'hash',
			v => [ $customer_payment_id ]);
		
		if ($tmp{cash} && $tmp{vendor_id} && $tmp{post_id}) {
			$s->db_q("UPDATE transactions SET post_date=NULL, ref_date=post_date
				WHERE trans_id=?
				",undef,
				v => [ $tmp{trans_id} ]);

			$s->db_q("UPDATE postings SET ref='vendor', ref_id=?
				WHERE post_id=?
				",undef,
				v => [ $tmp{vendor_id}, $tmp{post_id} ]);
			
			$s->db_q("SELECT post_transaction(?)",undef, v => [ $tmp{trans_id} ]);
		}

		$s->db_q("UPDATE order_payments SET customer_payment_id=?
			WHERE order_payment_id=?
			",undef,
			v => [ $customer_payment_id, $ref->{order_payment_id} ]);
	
		$s->db_insert('invoice_payments',{
			invoice_id => $invoice_id,
			amount => $ref->{amount},
			ref => 'customer_payment',
			ref_id => $customer_payment_id,
			});

		if ($ref->{till_method}) {
			my %last = $s->db_q("
				SELECT *
				FROM till_transactions_v
				WHERE location_id=?
				ORDER BY created_ts desc, till_transaction_id desc
				LIMIT 1
				",'hash',
				v => [ $hash{location_id} ]);

			unless($last{till_transaction_id}) {
				croak "Need to balance till first";
			}

			my $cash_balance = $last{cash_balance};
			my $cash_in = 0;
			if ($ref->{cash}) {
				#$cash_in = $ref->{amount};
				$cash_balance = sprintf "%.2f", $cash_balance+$ref->{amount};
			}

			my $till_transaction_id = $s->db_insert('till_transactions',{
				location_id => $hash{location_id},
				funit_id => $hash{funit_id},
				employee_id => $s->{employee_id},
				cash_balance => $cash_balance,
				cash_out => 0,
				cash_in => 0,
				cash_adjustment => 0,
				},'till_transaction_id');

			$s->db_q("UPDATE customer_payments SET till_transaction_id=?
				WHERE customer_payment_id=?
				",undef,
				v => [ $till_transaction_id, $customer_payment_id ]);

		}
	}

	$s->db_q("UPDATE orders SET order_status='closed', order_ts=tz_now(),
			order_type='order', close_ts=tz_now()
		WHERE order_id=?
		",undef,
		v => [ $hash{order_id} ]);

	$s->{dbh}->commit;

	if ($s->{in}{cashgift}) {
		$s->notify("Gift Card Cashed Out");
	} else {
		$s->notify("Order closed");
	}

	$s->redirect(function => 'pos',
		params => "location_id=$hash{location_id}");
}

sub deletediscount {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	my %hash = erp::object::order::load($s->{o},$s);

	if ($hash{close_ts}) {
		$s->alert("Order is closed.  Can not delete discount");
		return;
	}

	if ($hash{discount}) {
		$s->{dbh}->begin_work;

		$s->db_q("UPDATE order_items SET unit_price=unit_price/((100.0-?)/100.0),
				discounted=NULL
			WHERE order_id=?
			AND item_id IS NOT NULL
			",undef,
			v => [ $hash{discount}, $hash{order_id} ]);

		$s->db_q("UPDATE orders SET discount=NULL
			WHERE order_id=?
			",undef,
			v => [ $hash{order_id} ]);

		$s->{dbh}->commit;

		$s->notify("Discount removed");
	}

	$s->redirect(function => 'pos',
		subroutine => 'display',
		params => "order_id=$s->{in}{order_id}");
}

sub discount {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	my %hash = erp::object::order::load($s->{o},$s);

	if ($hash{close_ts}) {
		$s->alert("Order is closed.  Can not discount");
		return;
	}

	if ($s->{in}{f}) {
		unless($hash{discount}) {
			$s->alert("That order is not discounted");
			$s->redirect(function => 'pos',
				subroutine => 'display',
				params => "order_id=$s->{in}{order_id}");
			return;
		}

		unless($s->check_in_id('order_item_id')) {
			return;
		}

		my %item = $s->db_q("
			SELECT *
			FROM order_items_v
			WHERE order_item_id=?
			",'hash',
			v => [ $s->{in}{order_item_id} ]);

		if ($s->{in}{f} eq 'remove') {
			my $price = sprintf "%.2f", $item{unit_price}/((100.0-$hash{discount})/100.0);
			$s->db_q("UPDATE order_items SET unit_price=?, discounted=NULL
				WHERE order_item_id=?
				AND discounted IS TRUE
				",undef,
				v => [ $price, $s->{in}{order_item_id} ]);
		} elsif ($s->{in}{f} eq 'add') {
			my $price = sprintf "%.2f", $item{unit_price}*((100.0-$hash{discount})/100.0);
			$s->db_q("UPDATE order_items SET unit_price=?, discounted=TRUE
				WHERE order_item_id=?
				AND discounted IS NULL
				",undef,
				v => [ $price, $item{order_item_id} ]);
		}

		$s->redirect(function => 'pos',
			subroutine => 'display',
			params => "order_id=$s->{in}{order_id}");
		return;
	}

	if ($hash{discount}) {
		$s->alert("Order is already discounted");
		$s->redirect(function => 'pos',
			subroutine => 'display',
			params => "order_id=$s->{in}{order_id}");
		return;
	}

	if ($s->{in}{process}) {
		unless($s->{in}{discount} =~ m/^\d{1,2}$/) {
			$s->alert("$s->{in}{discount} is not a valid discount (must be between 0 and 99)");
			return;
		}

		$s->{dbh}->begin_work;

		$s->db_q("UPDATE order_items SET unit_price=(unit_price*((100.0-?)/100.0))::numeric(20,2), discounted=TRUE
			WHERE order_id=?
			AND item_id IS NOT NULL
			",undef,
			v => [ $s->{in}{discount}, $hash{order_id} ]);

		$s->db_q("UPDATE orders SET discount=?
			WHERE order_id=?
			",undef,
			v => [ $s->{in}{discount}, $hash{order_id} ]);

		$s->{dbh}->commit;

		$s->notify("Discount applied");

		#$s->{content} .= $s->dump(\%hash); return;
		$s->redirect(function => 'pos',
			subroutine => 'display',
			params => "order_id=$s->{in}{order_id}");
		return;
	}

	$s->add_action(function => 'pos',
		icon => 'home',
		subroutine => 'display',
		title => 'Display',
		params => "order_id=$s->{in}{order_id}");


	$s->tt('ct_consign/discount.tt', { s => $s, hash => \%hash });
}

sub delete {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	unless($s->{in}{confirm}) {
		$s->{confirm_no} = "$s->{ubase}/$s->{object}/$s->{function}/display?order_id=$s->{in}{order_id}";
		$s->confirm("Are you sure");
		return;
	}

	my %hash = $s->db_q("
		SELECT *
		FROM orders
		WHERE order_id=?
		",'hash',
		v => [ $s->{in}{order_id} ]);

	if ($hash{order_id}) {
		$s->{dbh}->begin_work;
	
		foreach my $t (qw(order_payments order_items shipping orders)) {
			$s->db_q("DELETE FROM $t WHERE order_id=?",undef, v => [ $s->{in}{order_id} ]);
		}
	
		$s->{dbh}->commit;
	}

	$s->redirect(function => 'pos',
		params => "location_id=$hash{location_id}");
}

sub payaccount {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	$s->add_action(function => 'pos',
		subroutine => 'display',
		icon => 'home',
		title => 'Display',
		params => "order_id=$s->{in}{order_id}");

	$s->tt('ct_consign/payaccount.tt', { s => $s, });
}

sub cashgift {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	$s->add_action(function => 'pos',
		icon => 'home',
		subroutine => 'display',
		title => 'Display',
		params => "order_id=$s->{in}{order_id}");

	if ($s->{in}{process} && $s->{in}{ct_consign_id}) {
		$s->db_q("UPDATE orders SET customer_id=t.customer_id
			FROM ct_consign t
			WHERE t.ct_consign_id=?
			AND orders.order_id=?
			",undef,
			v => [ $s->{in}{ct_consign_id}, $s->{in}{order_id} ]);
	}

	my %hash = erp::object::order::load($s->{o},$s);

	if (scalar @{$hash{items}}) {
		$s->redirect(function => 'pos',
			subroutine => 'display',
			params => "order_id=$hash{order_id}");
		return;
	}

	%{$hash{customer}} = $s->db_q("
		SELECT ct_consign_id, name, customer_id
		FROM ct_consign
		WHERE customer_id=?
		",'hash',
		v => [ $hash{customer_id} ]);

	if ($s->{in}{process}) {
		$s->alert("Choose a customer account to apply giftcard balance") unless($s->{in}{ct_consign_id});
		unless($s->{in}{gift_card_id}) {
			$s->alert("Enter Gift Card Number");
		} else {
			my %gift = $s->db_q("
				SELECT g.*, CASE WHEN COALESCE(b.balance,0) > 0 THEN TRUE ELSE FALSE END as available_balance,
					b.balance
				FROM gift_cards g
					LEFT JOIN (
						SELECT p.ref_id as gift_card_id, sum(p.credit-p.debit) as balance
						FROM postings p
							JOIN transactions t ON p.trans_id=t.trans_id
								AND t.post_date IS NOT NULL
						WHERE p.ref='gift_card'
						AND p.account_id=gl_account('gift')
						GROUP BY 1
						) b ON g.gift_card_id=b.gift_card_id
				WHERE g.gift_card_id=?
				",'hash',
				v => [ $s->{in}{gift_card_id} ]);
			
			unless($gift{gift_card_id}) {
				$s->alert("That is not a valid gift card number");
			} elsif (!$gift{available_balance}) {
				$s->alert("That gift card does not have a balance left");
			} else {
				$s->{in}{balance} = $gift{balance};
			}
		}

		unless($s->{message}) {
			unless($s->{in}{confirm}) {
				$s->tt('ct_consign/cashgift_confirm.tt', { s => $s, hash => \%hash });
				return;
			}

#			$s->alert("Yes, you thought this was done, but it's not yet...almost though, Chris still needs to fix this");
			# so the process here is to create a line entry for customer credit for that amount
			# and then add a gift card payment for the balance
			# and then close it.

			$s->{dbh}->begin_work;

			my $item_id = $s->db_q("
				SELECT c.item_id
				FROM orders o
					JOIN ct_consign c ON o.customer_id=c.customer_id
				WHERE o.order_id=?
				",'scalar',
				v => [ $s->{in}{order_id} ]);

			$s->db_insert('order_items',{
				order_id => $s->{in}{order_id},
				item_type => 'gift_card',
				description => 'GiftCard',
				item_id => $item_id,
				qty => 1, 
				unit_price => $s->{in}{balance},
				});

			my $payment_method_id = $s->db_q("
				SELECT payment_method_id
				FROM payment_methods
				WHERE gift_card IS TRUE
				",'scalar');

			$s->db_insert('order_payments',{
				order_id => $s->{in}{order_id},
				payment_method_id => $payment_method_id,
				amount => $s->{in}{balance},
				cash_change => 0,
				gift_card_id => $s->{in}{gift_card_id},
				});

			$s->{dbh}->commit;

			$s->redirect(function => 'pos',
				subroutine => 'close',
				params => "order_id=$s->{in}{order_id}&cashgift=1");

			return;
		}
	}

	$s->tt('ct_consign/cashgift.tt', { s => $s, hash => \%hash });
}

sub addgift {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	$s->add_action(function => 'pos',
		icon => 'home',
		subroutine => 'display',
		title => 'Display',
		params => "order_id=$s->{in}{order_id}");

	$s->tt('ct_consign/addgift.tt', { s => $s, });
}

sub cashcheck {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	$s->add_action(function => 'pos',
		icon => 'home',
		subroutine => 'display',
		title => 'Display',
		params => "order_id=$s->{in}{order_id}");

	my %hash = erp::object::order::load($s->{o},$s);

	my $cash_customer_id = $s->db_q("
		SELECT customer_id
		FROM customers
		WHERE cash IS TRUE
		",'scalar');

	if ($s->{in}{check_num}) {
		my %check = $s->db_q("
			SELECT c.check_id, c.amount, cc.vendor_id, cc.customer_id,
				cc.name, cc.ct_consign_id, c.check_date,
				(SELECT array_to_string(array_agg(v.voucher_id),',')
				FROM voucher_checks v
				WHERE v.check_id=c.check_id) as voucher_ids
			FROM checks c
				JOIN ct_consign cc ON c.vendor_id=cc.vendor_id
			WHERE c.check_num=?
			",'hash',
			v => [ $s->{in}{check_num} ]);

		if ($check{check_id}) {
			unless($s->{in}{confirm}) {
				$s->tt('ct_consign/cashcheck_confirm.tt', { s => $s, check => \%check });
				#$s->{content} .= $s->dump(\%check);
				return;
			}
		
#			$s->{content} .= $s->dump(\%check);
#			return;

			$s->{notransaction} = 1;
			$s->{dbh}->begin_work;

			$s->{in}{confirm} = 1; # to avoid confirmation boxes

			$s->{in}{check_id} = $check{check_id};

			erp::object::check::void::main($s);

			if ($s->{message}) {
				$s->{dbh}->rollback;
				return;
			}

			foreach my $vid (split ',', $check{voucher_ids}) {
				$s->{in}{voucher_id} = $vid;
				erp::object::voucher::unpost::main($s);
			
				if ($s->{message}) {
					$s->{dbh}->rollback;
					return;
				}

				$s->db_q("DELETE FROM voucher_items WHERE voucher_id=?",undef, v => [ $s->{in}{voucher_id} ]);
				$s->db_q("DELETE FROM vouchers WHERE voucher_id=?",undef, v => [ $s->{in}{voucher_id} ]);
			}

			# now, we need to take this amount and convert it from vendor to customer money
			# and we might need to create a customer account at this point for this person
			# wow, what a pain in the ass....
			unless($check{customer_id}) {
				$check{customer_id} = $s->db_insert('customers',{
					employee_id => $s->{employee_id},
					email_phone => $check{ct_consign_id},
					company => $check{name},
					individual => 0,
					},'customer_id');

				$s->db_q("UPDATE ct_consign SET customer_id=?
					WHERE ct_consign_id=?
					",undef,
					v => [ $check{customer_id}, $check{ct_consign_id} ]);
			}
			
			my $trans_id = $s->db_insert('transactions',{
				funit_id => 1000,
				employee_id => $s->{employee_id},
				ref => 'ct_consign',
				ref_id => $check{ct_consign_id},
				description => 'Convert Check to Customer Credit',
				},'trans_id');

			$s->db_q("SELECT gl_debit(?,'vendor',?,gl_account('cc'),NULL,?,NULL)",undef,
				v => [ $trans_id, $check{vendor_id}, $check{amount} ]);
			$s->db_q("SELECT gl_credit(?,'customer',?,gl_account('cc'),NULL,?,NULL)",undef,
				v => [ $trans_id, $check{customer_id}, $check{amount} ]);

			$s->db_q("SELECT post_transaction(?)",undef, v => [ $trans_id ]);

			$s->db_q("UPDATE orders SET customer_id=?
				WHERE order_id=?
				",undef,
				v => [ $check{customer_id}, $s->{in}{order_id} ])
				if ($hash{customer_id} eq $cash_customer_id);
					
			$s->{dbh}->commit;
			
			$s->notify("Vendor Check Voided and Converted to Store Credit");
			$s->redirect(function => 'pos',
				subroutine => 'display',
				params => "order_id=$s->{in}{order_id}");
			return;
		} else {
			$s->alert("Sorry that check does not exist");
		}
	}

	$s->tt('ct_consign/cashcheck.tt', { s => $s, });
}

sub display {
	my $s = shift;

	return unless($s->check_in_id('order_id'));

	$s->{cash_customer_id} = $s->db_q("
		SELECT customer_id
		FROM customers
		WHERE cash IS TRUE
		",'scalar');

	if ($s->{in}{account_amount}) {
		if ($s->{in}{ct_consign_id}) {
			my %tmp = $s->db_q("
				SELECT *
				FROM ct_consign
				WHERE ct_consign_id=?
				",'hash',
				v => [ $s->{in}{ct_consign_id} ]);

			if ($tmp{customer_id}) {
				$s->db_update_key('orders','order_id',$s->{in}{order_id},{
					customer_id => $tmp{customer_id},
					});
			}
		}
		my $item_id;
		if ($s->{in}{account}) {
			$item_id = $s->db_q("
				SELECT c.item_id
				FROM orders o
					JOIN ct_consign c ON o.customer_id=c.customer_id
				WHERE o.order_id=?
				",'scalar',
				v => [ $s->{in}{order_id} ]);

			unless($item_id) {
				$s->tt('ct_consign/addgift_account.tt', { s => $s, });
				return;
			}
		}

		$s->db_insert('order_items',{
			order_id => $s->{in}{order_id},
			item_type => 'gift_card',
			description => 'GiftCard',
			item_id => $item_id,
			qty => 1, 
			unit_price => $s->{in}{account_amount},
			});
	}

	if ($s->{in}{gift_amount}) {
		# create a new card
		my $gift_card_id = $s->db_insert('gift_cards',{
			name => $s->{in}{name} || 'unknown',
			amount => $s->{in}{gift_amount},
			employee_id => $s->{employee_id},
			},'gift_card_id');

#		my %card = $s->db_q("
#			SELECT g.gift_card_id, g.amount, 
#				count(p.post_id) as postings, count(oi.order_id) as orders
#			FROM gift_cards g
#				LEFT JOIN order_items oi ON g.gift_card_id=oi.gift_card_id
#				LEFT JOIN postings p ON g.gift_card_id=p.ref_id
#					AND p.ref='gift_card'
#			WHERE g.gift_card_id=?
#			GROUP BY 1,2
#			",'hash',
#			v => [ $s->{in}{gift_card_id} ]);
#
#		unless($card{gift_card_id}) {
#			$s->alert("Sorry, that is not a valid gift card ID");		
#		} elsif ($card{orders}) {
#			$s->alert("Sorry, that gift card has already been added to an order");
#		} elsif ($card{postings}) {
#			$s->alert("Sorry, that gift card has already been activated");
#		} else {
		$s->db_insert('order_items',{
			order_id => $s->{in}{order_id},
			item_type => 'gift_card',
			description => "GiftCard $gift_card_id",
			qty => 1, 
			unit_price => $s->{in}{gift_amount},
			gift_card_id => $gift_card_id,
			});
#		}
	}

	if ($s->{in}{payment_amount}) {
		$s->db_insert('order_items',{
			order_id => $s->{in}{order_id},
			item_type => 'pay_account',
			description => 'Account Payment',
			qty => 1, 
			unit_price => $s->{in}{payment_amount},
			});
	}

	if ($s->{in}{delete}) {
		$s->db_q("DELETE FROM order_items
			WHERE order_item_id=?
			AND order_id=?
			",undef,
			v => [ $s->{in}{delete}, $s->{in}{order_id} ]);
	}

	if ($s->{in}{deletep}) {
		$s->db_q("DELETE FROM order_payments
			WHERE order_payment_id=?
			AND order_id=?
			AND customer_payment_id IS NULL
			",undef,
			v => [ $s->{in}{deletep}, $s->{in}{order_id} ]);

		# skip this for now
#		# if there are no store credit payments left, then convert this back to a cash customer
#		my $storecredit = $s->db_q("
#			SELECT count(op.*)
#			FROM order_payments op
#				JOIN payment_methods pm ON op.payment_method_id=pm.payment_method_id
#					AND pm.store_credit IS TRUE
#			WHERE op.order_id=?
#			",'scalar',
#			v => [ $s->{in}{order_id} ]);
#
#		unless($storecredit) {
#			my $customer_id = $s->db_q("
#				SELECT customer_id
#				FROM customers
#				WHERE cash IS TRUE
#				",'scalar');
#
#			$s->db_q("UPDATE orders SET customer_id=?
#				WHERE order_id=?
#				AND customer_id!=?
#				",undef,
#				v => [ $customer_id, $s->{in}{order_id}, $customer_id ]);
#		}
	}

	if ($s->{in}{additem}) {
		my %input = $s->in_to_hash('line',1);
		#$s->{content} .= $s->dump(\%input); return;

		my %order = $s->db_q("
			SELECT o.*, s.ship_id
			FROM orders o
				LEFT JOIN shipping s ON o.order_id=s.order_id
			WHERE o.order_id=?
			",'hash',
			v => [ $s->{in}{order_id} ]);

		foreach my $n (keys %input) {
			my $ref = $input{$n};
			next unless($ref->{item_id});

			my %item = $s->db_q("
				SELECT *
				FROM items_v
				WHERE item_id=?
				",'hash',
				v => [ $ref->{item_id} ]);

			if ($item{item_id}) {
				# for now, in POS, we assume the price includes sales tax
				# so we need to modify the unit price so when tax gets calculated
				# it's correct.
				
				my $price = $ref->{unit_price} || $item{unit_price} || 0;
				my $discounted;
				if ($order{discount}) {
					$price = sprintf "%.2f", $price*((100.0-$order{discount})/100.0);
					$discounted = 1;
				}

				my $order_item_id = $s->db_insert('order_items',{
					order_id => $s->{in}{order_id},
					item_type => 'item',
					ship_id => $order{ship_id},
					pt_location_id => $order{location_id},
					qty => $s->{in}{qty} || 1,
					unit_price => $price,
					item_id => $item{item_id},
					discounted => $discounted,
					},'order_item_id');

			} else {
				$s->alert("Sorry, $ref->{item_id} is not a valid itemID");
			}
		}
	}

	my %hash = erp::object::order::load($s->{o},$s);

	@{$hash{payments}} = $s->db_q("
		SELECT *
		FROM order_payments_v
		WHERE order_id=?
		ORDER BY order_payment_id
		",'arrayhash',
		v => [ $hash{order_id} ]);

	%{$hash{balance}} = $s->db_q("
		SELECT x.order_balance, x.gl_credit_balance, x.store_credit_payments,
			CASE WHEN x.order_balance > 0 AND x.gl_credit_balance-x.store_credit_payments > x.order_balance 
				THEN x.order_balance
			WHEN x.order_balance > 0 AND x.gl_credit_balance-x.store_credit_payments < x.order_balance
				THEN x.gl_credit_balance-x.store_credit_payments
				ELSE 0.00 END as apply_credit_balance,
			CASE WHEN x.store_credit_payments > 0 THEN
				x.gl_credit_balance-x.store_credit_payments
				ELSE NULL END as remaining_balance
		FROM (
			SELECT (
				SELECT (COALESCE(?,0::numeric)-COALESCE(sum(p.amount),0))::numeric(10,2)
				FROM orders o
					LEFT JOIN order_payments p ON o.order_id=p.order_id
				WHERE o.order_id=?
				) as order_balance,
				(
				SELECT sum(z.balance)
				FROM (
					SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric as balance
					FROM postings p
					WHERE p.ref='customer'
					AND p.ref_id=?
					AND p.account_id=gl_account('cc')
					UNION ALL
					SELECT COALESCE(sum(p.credit-p.debit),0.00)::numeric as balance
					FROM ct_consign c
						JOIN postings p ON p.ref='vendor' AND p.ref_id=c.vendor_id
							AND p.account_id=gl_account('cc')
					WHERE c.customer_id=?
					AND c.vendor_id IS NOT NULL
					) z
				) as gl_credit_balance,
				COALESCE((
				SELECT sum(op.amount)
				FROM order_payments_v op 
				WHERE op.order_id=?
				AND op.store_credit IS TRUE
				),0.00) as store_credit_payments
			) x
		",'hash',
		v => [ $hash{summary}{total}, $s->{in}{order_id}, $hash{customer_id}, $hash{customer_id}, $s->{in}{order_id} ]);


	if ($hash{balance}{apply_credit_balance} ne '0.00' 
		&& !$hash{balance}{apply_credit_balance} =~ m/^-/) {
		#$s->{content} .= $s->dump(\%hash); return;

		my $pm = $s->db_q("
			SELECT payment_method_id
			FROM payment_methods
			WHERE store_credit IS TRUE
			",'scalar');

		$s->redirect(function => 'pos',	
			subroutine => 'pay',
			params => "payment_method_id=$pm&credit_amount=$hash{balance}{apply_credit_balance}&order_id=$s->{in}{order_id}");
		return;
	}


	$s->add_action(function => 'pos',
		icon => 'list',
		title => 'Orders',
		params => "location_id=$hash{location_id}");

	$s->add_action(function => 'pos',
		icon => 'usd',
		subroutine => 'pay',
		title => 'Pay',
		class => 'nextaction',
		params => "order_id=$hash{order_id}")
		if (scalar @{$hash{items}} && $hash{balance}{order_balance} ne '0.00');

	$s->add_action(function => 'pos',
		subroutine => 'discount',
		icon => 'tag',
		title => 'Discount',
		params => "order_id=$hash{order_id}")
		if (scalar @{$hash{items}} && !$hash{discount});

	$s->add_action(function => 'pos',
		subroutine => 'cashcheck',
		icon => 'download-alt',
		title => 'Cash Check',
		params => "order_id=$hash{order_id}")
		if (scalar @{$hash{items}} && $hash{balance}{order_balance} ne '0.00');

	$s->add_action(function => 'pos',
		subroutine => 'addgift',
		icon => 'gift',
		title => 'Add GiftCert',
		params => "order_id=$hash{order_id}");

	$s->add_action(function => 'pos',
		subroutine => 'cashgift',
		icon => 'download-alt',
		title => 'Apply GiftCert',
		params => "order_id=$hash{order_id}")
		unless(scalar @{$hash{items}});

	$s->add_action(function => 'pos',
		subroutine => 'payaccount',
		icon => 'user',
		title => 'Pay Account',
		params => "order_id=$hash{order_id}")
		if ($hash{customer_id} ne $s->{cash_customer_id} && $hash{balance}{gl_credit_balance} < 0);

	$s->add_action(function => 'pos',
		subroutine => 'close',
		title => 'Close',
		icon => 'ok',
		class => 'nextaction',
		params => "order_id=$hash{order_id}")
		if (scalar @{$hash{payments}} && $hash{balance}{order_balance} eq '0.00');

	$s->add_action(function => 'pos',
		subroutine => 'delete',
		icon => 'ban-circle',
		title => 'Void',
		params => "order_id=$hash{order_id}");

	$s->tt('ct_consign/pos.tt', { s => $s, hash => \%hash });

	#$s->{content} .= $s->dump(\%hash);
}

sub search {
	my $s = shift;

	my @list;
	
	if ($s->{in}{q} =~ m/^\d+$/) {
		@list = $s->db_q("
			SELECT ct_consign_id, name, customer_id, vendor_id
			FROM ct_consign
			WHERE ct_consign_id=?
			ORDER BY name
			",'arrayhash',
			v => [ $s->{in}{q} ]);
	} else {
		@list = $s->db_q("
			SELECT ct_consign_id, name, customer_id, vendor_id
			FROM ct_consign
			WHERE name~*?
			ORDER BY name
			",'arrayhash',
			v => [ $s->{in}{q} ]);
	}

	$s->{content_type} = 'application/json';
	$s->{content} = '[';
	my @kv;
	foreach my $ref (@list) {
		$ref->{name} =~ s/"//g;
		if ($s->{in}{account_amount}) {
			push @kv, qq({ "url" : "$s->{uof}/display?ct_consign_id=$ref->{ct_consign_id}&order_id=$s->{in}{order_id}&account=1&account_amount=$s->{in}{account_amount}", "name" : "$ref->{name}" });
		} elsif ($s->{in}{payment_form}) {
			push @kv, qq({ "ct_consign_id" : "$ref->{ct_consign_id}", "name" : "$ref->{name}" });
		} else {
			if ($ref->{customer_id}) {
				push @kv, qq({ "url" : "$s->{uof}/setcustomer?customer_id=$ref->{customer_id}&order_id=$s->{in}{order_id}", "name" : "$ref->{name}" });
			} elsif ($ref->{vendor_id}) {
				push @kv, qq({ "url" : "$s->{uof}/setcustomer?vendor_id=$ref->{vendor_id}&order_id=$s->{in}{order_id}", "name" : "$ref->{name}" });
			}
		}
	}
	$s->{content} .= (join ',', @kv);
	$s->{content} .= ']';
}
1;
