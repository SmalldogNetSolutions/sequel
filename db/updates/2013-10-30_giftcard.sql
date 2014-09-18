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
