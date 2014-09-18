package cherryt::object::ct_consign::create;

use strict;
use Carp;

sub main {
	my $s = shift;

	$s->add_action(function => 'list');

	if ($s->{in}{process}) {
		$s->alert("Please enter a name") unless($s->{in}{name});
		$s->alert("Please choose an account type") unless($s->{in}{cash});
		$s->alert("Please enter a consignment percent or a consignment fee") unless($s->{in}{consign_percent} || $s->{in}{consign_fee});

		unless($s->{message}) {
			unless($s->{in}{ct_consign_id}) {
				$s->{in}{ct_consign_id} = $s->db_q("SELECT max(ct_consign_id)+1
					FROM ct_consign
					",'scalar');
			}

			$s->{dbh}->begin_work;
			
			my $item_type_id = $s->db_q("
				SELECT *
				FROM item_types
				WHERE name='Consignment'
				",'scalar');

			unless($item_type_id) {
				$item_type_id = $s->db_insert('item_types',{ name => 'Consignment' },'item_type_id');
			}

			$s->db_insert('items',{
				item_id => $s->{in}{ct_consign_id},
				employee_id => $s->{employee_id},
				item_type_id => $item_type_id,
				name => "$s->{in}{ct_consign_id}",
				});

			if ($s->{in}{cash} eq 'true') {
				my $legal_name;
				if ($s->{in}{name} =~ m/^(.+),\s*(.+)$/) {
					$legal_name = "$2 $1";
				}

				my $profile_id = $s->db_insert('profiles',{
					organization => $s->{in}{name},
					individual => 0,
					legal_name => $legal_name,
					},'profile_id');

				my $vendor_id = $s->db_insert('vendors',{
					profile_id => $profile_id,
					employee_id => $s->{employee_id},
					account => $s->{in}{ct_consign_id},
					},'vendor_id');

				if ($s->{in}{consign_fee}) {
					$s->{in}{consign_percent} = 0;
				} else {
					$s->{in}{consign_fee} = '';
				}

				$s->db_insert('ct_consign',{
					ct_consign_id => $s->{in}{ct_consign_id},
					name => $s->{in}{name},
					item_id => $s->{in}{ct_consign_id},
					vendor_id => $vendor_id,
					cash => $s->{in}{cash},
					consign_fee => $s->{in}{consign_fee},
					consign_percent => $s->{in}{consign_percent},
					});
			} else {
				my $customer_id = $s->db_insert('customers',{
					employee_id => $s->{employee_id},
					email_phone => $s->{in}{ct_consign_id},
					company => $s->{in}{name},
					individual => 0,
					},'customer_id');
	
				$s->db_insert('ct_consign',{
					ct_consign_id => $s->{in}{ct_consign_id},
					name => $s->{in}{name},
					item_id => $s->{in}{ct_consign_id},
					customer_id => $customer_id,
					cash => $s->{in}{cash},
					consign_percent => $s->{in}{consign_percent},
					});
			}

			$s->{dbh}->commit;

			$s->redirect(function => 'display');
			return;
		}
	}

	$s->tt('ct_consign/create.tt', { s => $s, });
}

1;
