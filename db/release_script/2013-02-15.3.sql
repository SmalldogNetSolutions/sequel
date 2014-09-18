--start db/procedures/post_ct_invoice.sql

CREATE OR REPLACE FUNCTION post_ct_invoice (integer)
RETURNS integer AS $$
DECLARE
	invoice_rec	record;
	var_trans_id	integer;
	rec			record;
	res_rec		record;
	cost_rec	record;
BEGIN

	SELECT INTO invoice_rec i.invoice_id, i.customer_id, i.amount,
		i.customer_name, o.funit_id,
		date(i.created_ts) as created_date,
		s.accounting, s.cash_accounting
	FROM invoices_v i
		JOIN orders o ON i.order_id=o.order_id
		JOIN sitedata s ON s.id=1
	WHERE i.invoice_id=$1;

	INSERT INTO transactions (funit_id, ref, ref_id, ref_date, description) VALUES
		(invoice_rec.funit_id, 'invoice', $1, invoice_rec.created_date, invoice_rec.customer_name)
		RETURNING trans_id INTO var_trans_id;

	FOR rec IN SELECT v.account_id, v.item_id, v.item_type, sum(v.total_price) as amount
		FROM order_items_v v
		WHERE invoice_id=invoice_rec.invoice_id
		GROUP BY 1,2,3
		ORDER BY 1,2 LOOP

		IF rec.item_id IS NULL THEN
			IF rec.item_type = 'gift_card' THEN
				PERFORM gl_credit(var_trans_id, 'invoice', invoice_rec.invoice_id, gl_account('gift'), NULL, rec.amount, NULL);
			ELSE
				PERFORM gl_credit(var_trans_id, 'customer', invoice_rec.customer_id, rec.account_id, NULL, rec.amount, NULL);
			END IF;
		ELSE
			PERFORM gl_credit(var_trans_id, 'item', rec.item_id, rec.account_id, NULL, rec.amount, NULL);
		END IF;

	END LOOP;

	FOR rec IN SELECT sum(v.tax_amount) as amount
		FROM order_items v
		WHERE invoice_id=invoice_rec.invoice_id
		LOOP

		IF rec.amount != 0 THEN
			PERFORM gl_credit(var_trans_id, NULL, NULL, gl_account('tax'), NULL, rec.amount, NULL);
		END IF;
	END LOOP;

	PERFORM gl_debit(var_trans_id, 'customer', invoice_rec.customer_id, gl_account('ar'), NULL, invoice_rec.amount, NULL);

	--we should also deal with the cost portion of this, which is to hit cogs and balance it
	--off with hitting customer credit
	FOR cost_rec IN SELECT 
			CASE WHEN c.cash IS TRUE THEN 'vendor' ELSE 'customer' END as ref,
			CASE WHEN c.cash IS TRUE THEN c.vendor_id ELSE c.customer_id END as ref_id,
			CASE WHEN c.consign_fee IS NOT NULL THEN
				(sum(v.qty*(v.unit_price-c.consign_fee)))::numeric(10,2)
			ELSE 
				(sum(v.total_price)*c.consign_percent)::numeric(10,2)
			END as amount
		FROM order_items_v v
			JOIN ct_consign c ON v.item_id=c.item_id
		WHERE v.invoice_id=invoice_rec.invoice_id
		GROUP BY c.cash, c.vendor_id, c.customer_id, c.consign_percent, c.consign_fee
		ORDER BY 1,2 LOOP

		PERFORM gl_credit(var_trans_id, cost_rec.ref, cost_rec.ref_id, gl_account('cc'), NULL, cost_rec.amount, NULL);
		PERFORM gl_debit(var_trans_id, cost_rec.ref, cost_rec.ref_id, gl_account('cogs'), NULL, cost_rec.amount, NULL);
	END LOOP;

	PERFORM post_transaction(var_trans_id);

	RETURN var_trans_id;
END;
$$ LANGUAGE 'plpgsql';

--end db/procedures/post_ct_invoice.sql

