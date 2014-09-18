if (not -e "$ENV{HTTPD_ROOT}/logs/cherryt") {
    die "Need '$ENV{HTTPD_ROOT}/logs/cherryt' for logging.";
}
# now put it all together
my $common = <<END;
    Errorlog        logs/cherryt/error_log
    CustomLog       logs/cherryt/access_log sdnfw
    DocumentRoot    "/data/cherryt/content"
    DirectoryIndex  index.html index.php
	PerlPassEnv		HTTPD_ROOT
    PerlSetVar  	HTTPD_ROOT $ENV{HTTPD_ROOT}
	SetEnv			HTMLDOC_NOCGI yes
	SetEnv			BASE_URL /erp
	SetEnv			OBJECT_BASE erp
	SetEnv			CBASE cherryt
	SetEnv			APACHE_SERVER_NAME $ENV{APACHE_SERVER_NAME}
	SetEnv			IP_ADDR $ENV{IP_ADDR}
END

my %config;
if (-f "$ENV{HTTPD_ROOT}/conf/cherryt.conf") {
	open F, "$ENV{HTTPD_ROOT}/conf/cherryt.conf";
	while (my $l = <F>) {
		chomp $l;
		next if ($l =~ m/^#/);
		if ($l =~ m/^([^=]+)=(.+)$/) {
			$common .= "	SetEnv	$1	$2\n";
			$config{$1} = $2;
		}
	}
	close F;
}

$common .= <<END;
    PerlRequire 	"$ENV{HTTPD_ROOT}/cherryt/startup.pl"

	ServerName		$config{SERVER_NAME}
	<Location /erp>
		SetHandler		perl-script
    	PerlHandler     Apache::SdnFw
	</Location>

	Options -Indexes

	RewriteEngine	on
	RewriteRule ^(.*/)?\.svn/ - [F,L]
	RewriteRule ^(.+)-r[0-9]+(\.[^/]+)\$	\$1\$2	[R]
END

print <<END;
<VirtualHost $ENV{IP_ADDR}:$ENV{HTTP_PORT}>
$common
</VirtualHost>
END

unless($ENV{NO_HTTPS}) {

	print <<END;
<VirtualHost $ENV{IP_ADDR}:$ENV{HTTPS_PORT}>
	SSLEngine				On
	SSLCertificateFile		$ENV{HTTPD_ROOT}/smalldognet/certs/smalldognet.crt
	SSLCertificateKeyFile	$ENV{HTTPD_ROOT}/smalldognet/certs/smalldognet.key
	SSLCertificateChainFile $ENV{HTTPD_ROOT}/smalldognet/certs/ca_bundle.crt

$common
</VirtualHost>
END

}
