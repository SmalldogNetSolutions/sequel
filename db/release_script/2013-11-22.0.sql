--start db/updates/2013-11-21_fixsquare.sql

SELECT o.order_id, o.created_ts, i.invoice_id, cp.customer_payment_id, cp.deposit_id,
	s.payment_date
INTO tmp_squarefix
FROM order_items oi
	JOIN orders o ON oi.order_id=o.order_id
	JOIN invoices i ON oi.invoice_id=i.invoice_id
	JOIN order_payments op ON o.order_id=op.order_id
	JOIN customer_payments cp ON op.customer_payment_id=cp.customer_payment_id
	JOIN square_transaction_payments sp ON cp.customer_payment_id=sp.customer_payment_id
	JOIN square_transactions s ON sp.square_trans_id=s.square_trans_id
WHERE oi.description='Manual sale for unmatched square payment';

UPDATE orders SET created_ts=t.payment_date, order_ts=t.payment_date, close_ts=t.payment_date
FROM tmp_squarefix t
WHERE orders.order_id=t.order_id;

UPDATE invoices SET created_ts=t.payment_date
FROM tmp_squarefix t
WHERE invoices.invoice_id=t.invoice_id;

UPDATE customer_payments SET process_ts=t.payment_date
FROM tmp_squarefix t
WHERE customer_payments.customer_payment_id=t.customer_payment_id;

UPDATE deposits SET deposit_date=t.payment_date
FROM tmp_squarefix t
WHERE deposits.deposit_id=t.deposit_id;

SELECT t.trans_id, s.payment_date
INTO tmp_squarefix_trans
FROM tmp_squarefix s JOIN transactions t ON s.invoice_id=t.ref_id AND t.ref='invoice'
UNION ALL
SELECT t.trans_id, s.payment_date
FROM tmp_squarefix s JOIN transactions t ON s.customer_payment_id=t.ref_id AND t.ref='customer_payment'
UNION ALL
SELECT t.trans_id, s.payment_date
FROM tmp_squarefix s JOIN transactions t ON s.deposit_id=t.ref_id AND t.ref='deposit';

UPDATE transactions SET post_date=NULL, ref_date=t.payment_date
FROM tmp_squarefix_trans t
WHERE transactions.trans_id=t.trans_id;

SELECT post_transaction(t.trans_id)
FROM tmp_squarefix_trans t;

--end db/updates/2013-11-21_fixsquare.sql

