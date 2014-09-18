--just create one big order
INSERT INTO orders (order_type, order_status, customer_id, employee_id, funit_id, location_id)
VALUES ('pos','import',1002,1000,1000,1000);

INSERT INTO shipping (order_id, cost, state, zipcode)
SELECT o.order_id, 0, l.state, l.zipcode
FROM orders o
	JOIN locations l ON o.location_id=l.location_id
WHERE o.order_type='pos' AND o.order_status='import';

INSERT INTO order_items (order_id, item_type, ship_id, pt_location_id, qty, unit_price, item_id)
SELECT o.order_id, 'item', s.ship_id, o.location_id, 1, t.amount, t.ct_consign_id
FROM orders o
	JOIN shipping s ON o.order_id=s.order_id
	JOIN tmp_ct_feb t ON amount!=0
WHERE o.order_type='pos' AND o.order_status='import';

INSERT INTO invoices (order_id, created_ts)
SELECT o.order_id, '2013-02-02'
FROM orders o
WHERE o.order_type='pos' AND o.order_status='import';

UPDATE order_items SET invoice_id=i.invoice_id, account_id=gl_account('sales')
FROM invoices i
WHERE order_items.order_id=i.order_id
AND order_items.invoice_id IS NULL;

SELECT post_ct_invoice(i.invoice_id) FROM invoices i WHERE closed IS NULL;
UPDATE invoices SET closed=TRUE;

UPDATE orders SET order_type='order', order_status='closed', order_ts=tz_now(), close_ts=tz_now()
WHERE order_type='pos' AND order_status='import';

--reverse our accounts receivable for that invoice into retained earnings
INSERT INTO transactions (funit_id, ref_date, ref, ref_id, description)
SELECT t.funit_id, t.post_date, t.ref, t.ref_id, 'Initial Setup'
FROM transactions t
	JOIN invoices i ON t.ref_id=i.invoice_id
		AND i.created_ts='2013-02-02'
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
