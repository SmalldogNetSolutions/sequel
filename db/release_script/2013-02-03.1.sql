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

	FOR rec IN SELECT v.account_id, v.item_id, sum(v.total_price) as amount
		FROM order_items_v v
		WHERE invoice_id=invoice_rec.invoice_id
		GROUP BY 1,2 
		ORDER BY 1,2 LOOP

		IF rec.item_id IS NULL THEN
			PERFORM gl_credit(var_trans_id, 'customer', invoice_rec.customer_id, rec.account_id, NULL, rec.amount, NULL);
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
			(sum(v.total_price)*c.consign_percent)::numeric(10,2) as amount
		FROM order_items_v v
			JOIN ct_consign c ON v.item_id=c.item_id
		WHERE v.invoice_id=invoice_rec.invoice_id
		GROUP BY c.cash, c.vendor_id, c.customer_id, c.consign_percent
		ORDER BY 1,2 LOOP

		PERFORM gl_credit(var_trans_id, cost_rec.ref, cost_rec.ref_id, gl_account('cc'), NULL, cost_rec.amount, NULL);
		PERFORM gl_debit(var_trans_id, cost_rec.ref, cost_rec.ref_id, gl_account('cogs'), NULL, cost_rec.amount, NULL);
	END LOOP;

	PERFORM post_transaction(var_trans_id);

	RETURN var_trans_id;
END;
$$ LANGUAGE 'plpgsql';

--end db/procedures/post_ct_invoice.sql

--start db/updates/2013-02-01_import.sql

UPDATE tmp_ct_import SET ct_id=551 WHERE name='Lyle, Deana';
UPDATE tmp_ct_import SET ct_id=715 WHERE name='Hopkins, Kyle  Sunshine';

INSERT INTO ct_consign (ct_consign_id, name, cash, consign_percent)
SELECT ct_id, name, CASE WHEN ctype='CA' THEN TRUE ELSE FALSE END, cper::real/100::real
FROM tmp_ct_import t;

INSERT INTO items (item_type_id, item_id, employee_id, name)
SELECT 1000, t.ct_consign_id, 1000, t.ct_consign_id
FROM ct_consign t;
SELECT setval('items_item_id_seq',(SELECT max(item_id) FROM items),TRUE);

UPDATE ct_consign SET item_id=ct_consign_id;

ALTER TABLE ct_consign ADD COLUMN vendor_id int4;
ALTER TABLE ct_consign ADD CONSTRAINT ct_consign_id_fkey
FOREIGN KEY (vendor_id) REFERENCES vendors;
CREATE UNIQUE INDEX ct_consign_vendor_id ON ct_consign (vendor_id);

INSERT INTO vendors (name, employee_id, account)
SELECT name, 1000, ct_consign_id
FROM ct_consign
WHERE cash IS TRUE;
SELECT setval('vendors_vendor_id_seq',(SELECT max(vendor_id) FROM vendors),TRUE);

UPDATE ct_consign SET vendor_id=v.vendor_id
FROM vendors v
WHERE ct_consign.ct_consign_id::varchar=v.account;

INSERT INTO customers (email_phone, company, individual)
SELECT ct_consign_id, name, FALSE
FROM ct_consign
WHERE cash IS FALSE;
SELECT setval('customers_customer_id_seq',(SELECT max(customer_id) FROM customers),TRUE);

UPDATE ct_consign SET customer_id=v.customer_id
FROM customers v
WHERE ct_consign.ct_consign_id::varchar=v.email_phone;

INSERT INTO transactions (funit_id, ref, ref_id, description, ref_date)
SELECT 1000, 'ct_consign', c.ct_consign_id, 'Initial Balance', '2013-01-01'
FROM ct_consign c
	JOIN tmp_ct_import t ON c.ct_consign_id=t.ct_id
		AND t.balance!=0;

SELECT gl_credit(tt.trans_id, 
	CASE WHEN c.cash IS TRUE THEN 'vendor' ELSE 'customer' END, 
	CASE WHEN c.cash IS TRUE THEN c.vendor_id ELSE c.customer_id END, 
	gl_account('cc'), NULL, t.balance, NULL)
FROM ct_consign c
	JOIN tmp_ct_import t ON c.ct_consign_id=t.ct_id
		AND t.balance!=0
	JOIN transactions tt ON c.ct_consign_id=tt.ref_id
		AND tt.ref='ct_consign'
		AND tt.post_date IS NULL;

SELECT gl_debit(tt.trans_id, 
	CASE WHEN c.cash IS TRUE THEN 'vendor' ELSE 'customer' END, 
	CASE WHEN c.cash IS TRUE THEN c.vendor_id ELSE c.customer_id END, 
	gl_account('earn'), NULL, t.balance, NULL)
FROM ct_consign c
	JOIN tmp_ct_import t ON c.ct_consign_id=t.ct_id
		AND t.balance!=0
	JOIN transactions tt ON c.ct_consign_id=tt.ref_id
		AND tt.ref='ct_consign'
		AND tt.post_date IS NULL;

SELECT post_transaction(tt.trans_id)
FROM ct_consign c
	JOIN tmp_ct_import t ON c.ct_consign_id=t.ct_id
		AND t.balance!=0
	JOIN transactions tt ON c.ct_consign_id=tt.ref_id
		AND tt.ref='ct_consign'
		AND tt.post_date IS NULL;

--just create one big order
INSERT INTO orders (order_type, order_status, customer_id, employee_id, funit_id, location_id)
VALUES ('pos','import',1002,1000,1000,1000);

INSERT INTO shipping (order_id, cost, state, zipcode)
SELECT o.order_id, 0, l.state, l.zipcode
FROM orders o
	JOIN locations l ON o.location_id=l.location_id
WHERE o.order_type='pos' AND o.order_status='import';

--what items are not valid
--UPDATE tmp_ct_jan SET ct_consign_id=516 WHERE ct_consign_id=561;
--UPDATE tmp_ct_jan SET ct_consign_id=849 WHERE ct_consign_id=894;

INSERT INTO order_items (order_id, item_type, ship_id, pt_location_id, qty, unit_price, item_id)
SELECT o.order_id, 'item', s.ship_id, o.location_id, 1, t.amount, t.ct_consign_id
FROM orders o
	JOIN shipping s ON o.order_id=s.order_id
	JOIN tmp_ct_jan t ON amount!=0
WHERE o.order_type='pos' AND o.order_status='import';

INSERT INTO invoices (order_id, created_ts)
SELECT o.order_id, '2013-01-02'
FROM orders o
WHERE o.order_type='pos' AND o.order_status='import';

UPDATE order_items SET invoice_id=i.invoice_id, account_id=gl_account('sales')
FROM invoices i
WHERE order_items.order_id=i.order_id;

SELECT post_ct_invoice(i.invoice_id) FROM invoices i;
UPDATE invoices SET closed=TRUE;

UPDATE orders SET order_type='order', order_status='closed', order_ts=tz_now(), close_ts=tz_now()
WHERE order_type='pos' AND order_status='import';

--reverse our accounts receivable for that invoice into retained earnings
INSERT INTO transactions (funit_id, ref_date, ref, ref_id, description)
SELECT t.funit_id, t.post_date, t.ref, t.ref_id, 'Initial Setup'
FROM transactions t
WHERE t.ref='invoice';

SELECT gl_credit(tt.trans_id, p.ref, p.ref_id, gl_account('ar'), NULL, p.debit, NULL)
FROM transactions t
	JOIN transactions tt ON t.ref=tt.ref
		AND t.ref_id=tt.ref_id
		AND tt.post_date IS NULL
	JOIN postings p ON t.trans_id=p.trans_id
		AND p.account_id=gl_account('ar')
WHERE t.post_date IS NOT NULL;

SELECT gl_debit(tt.trans_id, p.ref, p.ref_id, gl_account('earn'), NULL, p.debit, NULL)
FROM transactions t
	JOIN transactions tt ON t.ref=tt.ref
		AND t.ref_id=tt.ref_id
		AND tt.post_date IS NULL
	JOIN postings p ON t.trans_id=p.trans_id
		AND p.account_id=gl_account('ar')
WHERE t.post_date IS NOT NULL;

SELECT post_transaction(t.trans_id)
FROM transactions t
WHERE t.ref='invoice'
AND t.post_date IS NULL;

--end db/updates/2013-02-01_import.sql

