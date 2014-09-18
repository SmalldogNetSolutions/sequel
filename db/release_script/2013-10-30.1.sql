--start db/updates/2013-10-30_giftcard.sql

CREATE TABLE tmp_ct_gift (
	legacy_code	varchar(32),
	name	varchar(255),
	amount	numeric(10,2),
	balance	numeric(10,2));
COPY tmp_ct_gift (legacy_code, name, amount, balance) FROM STDIN;
S001	giving tree	15	15
S002	giving tree	50	50
S003	giving tree	40	40
S004	giving tree	15	15
S005	giving tree	15	15
S006	giving tree	15	15
S007	Shayaiyda	20	4.87
S008	Flora	20	20
S009	Welty	50	50
S010	unknown	35	35
S011	Toombs	30	30
S012	Halbert	30	0
S013	Mandy R. 	20	20
S014	Erin	100	0
S015	Ramona	25	25
S016	Megan Tye	25	25
S017	Grant Tyree	50	50
S018	Birdie	20	20
S019	Satine	50	50
S020	Makayla	25	25
S021	Tyree	25	25
S022	Tyree	25	25
005	Bigbee	10	0
006	Rusty	10	0
007	OFC	50	0
008	Bigbee	10	0
009	Haug	40	0
010	giving tree	15	15
011	giving tree	15	15
012	giving tree	15	15
013	giving tree	15	15
014	giving tree	20	0
015	Doty	25	0
016	OFC	15	0
017	Kyrah	20	0
018	Emma	20	0
020	unknown	25	25
021	unknown	25	25
022	Mandy	25	0
023	unknown	15	0
024	unknown	15	0
025	unknown	20	0
026	void	0	0
027	unknown	30	0
028	unknown	25	25
029	unknown	30	30
030	Zwilling	25	0
031	giving tree	25	0
032	Philbook	40	0
033	giving tree	25	25
034	giving tree	25	0
035	unknown	30	0
036	Carol	50	50
037	giving tree	15	0
038	giving tree	15	0
039	giving tree	15	15
040	giving tree	15	0
041	giving tree	15	15
042	giving tree	15	15
043	giving tree	15	15
044	giving tree	15	0
045	unknown	45	0
046	unknown	20	0
047	Viv	20	0
048	unknown	15	0
049	unknown	15	0
050	Welty	50	0
051	unknown	20	0
052	Brewer	25	0
053	unknown	10	10
054	Montessori	50	0
055	Sofia	15	0
056	unknown	25	0
057	unknown	20	0
058	unknown	10	0
059	unknown	40	40
060	unknown	25	0
061	unknown	25	0
062	unknown	25	0
063	Rhya	10	0
089	Dorothy	25	25
065	Peter	25	0
066	Ivy	20	20
067	unknown	9.99	9.99
068	Rankin	15	0
069	Kimple	25	0
070	unknown	30	0
071	Kameah	20	0
072	King	25	25
073	unknown	30	30
074	Jen	25	0
075	giving tree	50	0
076	Cunningham	150	0
077	giving tree	15	15
078	giving tree	15	15
079	giving tree	15	15
080	giving tree	15	0
081	giving tree	15	15
082	giving tree	15	0
083	giving tree	15	15
084	giving tree	15	15
085	Bonnie	15	15
086	giving tree	30	30
090	Dorothy	25	25
091	Montessori	50	0
092	Orkila	50	50
093	Salmonberry	25	25
2016	Sutton	20	20
2018	Satine	15	15
\.

INSERT INTO gift_cards (legacy_code, name, amount, created_ts, employee_id)
SELECT legacy_code, name, amount, '2013-01-01', 1000
FROM tmp_ct_gift
ORDER BY legacy_code;

INSERT INTO transactions (funit_id, ref_date, ref, ref_id, description)
SELECT 1000, '2013-01-01', 'gift_card', g.gift_card_id,'Gift Card Import'
FROM gift_cards g;

SELECT gl_credit(t.trans_id,'gift_card',g.gift_card_id,gl_account('gift'),NULL,gt.balance,g.name)
FROM gift_cards g
	JOIN transactions t ON g.gift_card_id=t.ref_id
		AND t.ref='gift_card'
	JOIN tmp_ct_gift gt ON g.legacy_code=gt.legacy_code;

SELECT gl_debit(t.trans_id,'gift_card',g.gift_card_id,gl_account('earn'),NULL,gt.balance,g.name)
FROM gift_cards g
	JOIN transactions t ON g.gift_card_id=t.ref_id
		AND t.ref='gift_card'
	JOIN tmp_ct_gift gt ON g.legacy_code=gt.legacy_code;

SELECT post_transaction(t.trans_id)
FROM transactions t
WHERE t.ref='gift_card'
AND t.post_date IS NULL;

--end db/updates/2013-10-30_giftcard.sql

--start db/procedures/post_ct_invoice.sql

CREATE OR REPLACE FUNCTION post_ct_invoice (integer)
RETURNS integer AS $$
DECLARE
	invoice_rec	record;
	var_trans_id	integer;
	rec			record;
	res_rec		record;
	consign_rec	record;
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

	FOR rec IN SELECT v.account_id, v.item_id, v.item_type, oi.gift_card_id, sum(v.total_price) as amount
		FROM order_items_v v
			JOIN order_items oi ON v.order_item_id=oi.order_item_id
		WHERE v.invoice_id=invoice_rec.invoice_id
		GROUP BY 1,2,3,4
		ORDER BY 1,2 LOOP

		IF rec.item_id IS NULL THEN
			IF rec.item_type = 'gift_card' THEN
				IF rec.gift_card_id IS NULL THEN
					PERFORM gl_credit(var_trans_id, 'invoice', invoice_rec.invoice_id, gl_account('gift'), NULL, rec.amount, NULL);
				ELSE 
					PERFORM gl_credit(var_trans_id, 'gift_card', rec.gift_card_id, gl_account('gift'), NULL, rec.amount, NULL);
				END IF;
			ELSIF rec.item_type = 'pay_account' THEN
				PERFORM gl_credit(var_trans_id, 'customer', invoice_rec.customer_id, gl_account('cc'), NULL, rec.amount, NULL);
			ELSE
				PERFORM gl_credit(var_trans_id, 'customer', invoice_rec.customer_id, rec.account_id, NULL, rec.amount, NULL);
			END IF;
		ELSE
			IF rec.item_type = 'gift_card' THEN
				SELECT INTO consign_rec customer_id
				FROM ct_consign
				WHERE item_id=rec.item_id;

				PERFORM gl_credit(var_trans_id, 'customer', consign_rec.customer_id, gl_account('cc'), NULL, rec.amount, NULL);
			ELSE 
				PERFORM gl_credit(var_trans_id, 'item', rec.item_id, rec.account_id, NULL, rec.amount, NULL);
			END IF;
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
		AND v.item_type NOT IN ('gift_card')
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

