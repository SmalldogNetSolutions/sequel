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
