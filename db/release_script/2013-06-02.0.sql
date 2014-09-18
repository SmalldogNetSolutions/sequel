--start db/updates/2013-06-02_update.sql

UPDATE vendors SET name=v.name
FROM (
	SELECT c.vendor_id, c.name, v.name as vendor_name
	FROM ct_consign c
		JOIN vendors v ON c.vendor_id=v.vendor_id
	WHERE c.name!=v.name
	) v
WHERE vendors.vendor_id=v.vendor_id;

UPDATE customers SET company=v.name
FROM (
	SELECT c.customer_id, c.name, v.company as customer_name
	FROM ct_consign c
		JOIN customers v ON c.customer_id=v.customer_id
	WHERE c.name!=v.company
	) v
WHERE customers.customer_id=v.customer_id;

--end db/updates/2013-06-02_update.sql

--start db/triggers/ct_consign_after.sql

CREATE OR REPLACE FUNCTION ct_consign_after() RETURNS TRIGGER AS $$
BEGIN

	IF OLD.name!=NEW.name THEN
		IF NEW.vendor_id IS NOT NULL THEN
			UPDATE vendors SET name=NEW.name
			WHERE vendor_id=NEW.vendor_id;
		END IF;
		IF NEW.customer_id IS NOT NULL THEN
			UPDATE customers SET company=NEW.name
			WHERE customer_id=NEW.customer_id;
		END IF;
	END IF;

	RETURN NEW;
END;
$$ LANGUAGE 'plpgsql';

CREATE TRIGGER ct_consign_after AFTER UPDATE
ON ct_consign FOR EACH ROW EXECUTE PROCEDURE ct_consign_after();

--end db/triggers/ct_consign_after.sql

