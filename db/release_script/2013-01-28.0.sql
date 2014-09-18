--start db/updates/2013-01-28_install.sql

CREATE TABLE ct_consign (
	ct_consign_id	int4 not null primary key,
	created_ts	timestamp not null default tz_now(),
	name		varchar(255) not null,
	item_id		int4 unique references items,
	customer_id	int4 unique references customers,
	cash		boolean not null,
	consign_percent	numeric(5,4) not null,
	inactive_ts	timestamp);
GRANT ALL ON ct_consign TO sdnfw;

--end db/updates/2013-01-28_install.sql

