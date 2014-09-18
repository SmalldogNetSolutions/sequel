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
