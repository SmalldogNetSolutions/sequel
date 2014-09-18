--start db/updates/2013-03-27_squareup.sql

UPDATE transactions SET post_date=NULL WHERE ref='deposit';
DELETE FROM postings WHERE trans_id IN (SELECT trans_id FROM transactions WHERE ref='deposit');
DELETE FROM deposit_transactions;
DELETE FROM transactions WHERE trans_id IN (SELECT trans_id FROM transactions WHERE ref='deposit');
UPDATE customer_payments SET deposit_id=NULL WHERE deposit_id IS NOT NULL;
DELETE FROM deposits;

--end db/updates/2013-03-27_squareup.sql

