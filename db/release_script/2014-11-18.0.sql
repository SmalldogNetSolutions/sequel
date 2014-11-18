--start db/updates/2014-11-18_update.sql

--move balances into the correct place
SELECT c.ct_consign_id, c.cash, cb.balance as credit_balance,
	vb.balance as cash_balance, c.consign_percent,
	c.vendor_id, c.customer_id
INTO tmp_cashcredit_fix
FROM ct_consign c
	JOIN (
		SELECT p.ref_id as vendor_id, COALESCE(sum(p.credit-p.debit),0.00)::numeric as balance
		FROM postings p
		WHERE p.account_id=gl_account('cc')
		AND p.ref='vendor'
		GROUP BY 1
		) vb ON c.vendor_id=vb.vendor_id
	JOIN (
		SELECT p.ref_id as customer_id, COALESCE(sum(p.credit-p.debit),0.00)::numeric as balance
		FROM postings p
		WHERE p.account_id=gl_account('cc')
		AND p.ref='customer'
		GROUP BY 1
		) cb ON c.customer_id=cb.customer_id
WHERE c.vendor_id IS NOT NULL
AND c.customer_id IS NOT NULL;

DELETE FROM tmp_cashcredit_fix
WHERE cash_balance=0
AND credit_balance=0;

DELETE FROM tmp_cashcredit_fix
WHERE cash_balance=0
AND cash IS FALSE;

DELETE FROM tmp_cashcredit_fix
WHERE credit_balance=0
AND cash IS TRUE;

INSERT INTO transactions (funit_id, ref_date, ref, ref_id, description)
SELECT 1000, date(now()), 'ct_consign', x.ct_consign_id, 'Cash/Credit Adjustment'
FROM tmp_cashcredit_fix x;

SELECT gl_debit(t.trans_id,'vendor',x.vendor_id,gl_account('cc'),NULL,x.cash_balance,NULL)
FROM tmp_cashcredit_fix x
	JOIN transactions t ON x.ct_consign_id=t.ref_id
		AND t.ref='ct_consign'
		AND t.description='Cash/Credit Adjustment'
		AND t.post_date IS NULL
WHERE x.cash IS FALSE
AND x.cash_balance !=0;

SELECT gl_credit(t.trans_id,'customer',x.customer_id,gl_account('cc'),NULL,x.cash_balance,NULL)
FROM tmp_cashcredit_fix x
	JOIN transactions t ON x.ct_consign_id=t.ref_id
		AND t.ref='ct_consign'
		AND t.description='Cash/Credit Adjustment'
		AND t.post_date IS NULL
WHERE x.cash IS FALSE
AND x.cash_balance !=0;

SELECT gl_debit(t.trans_id,'customer',x.customer_id,gl_account('cc'),NULL,x.credit_balance,NULL)
FROM tmp_cashcredit_fix x
	JOIN transactions t ON x.ct_consign_id=t.ref_id
		AND t.ref='ct_consign'
		AND t.description='Cash/Credit Adjustment'
		AND t.post_date IS NULL
WHERE x.cash IS TRUE
AND x.credit_balance !=0;

SELECT gl_credit(t.trans_id,'vendor',x.vendor_id,gl_account('cc'),NULL,x.credit_balance,NULL)
FROM tmp_cashcredit_fix x
	JOIN transactions t ON x.ct_consign_id=t.ref_id
		AND t.ref='ct_consign'
		AND t.description='Cash/Credit Adjustment'
		AND t.post_date IS NULL
WHERE x.cash IS TRUE
AND x.credit_balance !=0;

SELECT count(post_transaction(t.trans_id))
FROM transactions t
WHERE t.description='Cash/Credit Adjustment'
AND t.post_date IS NULL;


--end db/updates/2014-11-18_update.sql

