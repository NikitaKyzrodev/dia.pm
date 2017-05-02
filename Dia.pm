no warnings;   

use Carp;
use Cwd;
use Data::Dumper;
use DBI;
use DBI::Const::GetInfoType;
use Digest::MD5;
use Encode;
use Fcntl qw(:DEFAULT :flock);
use File::Copy 'move';
use HTML::Entities;
use HTTP::Date;
use MIME::Base64;
use Number::Format;
use Time::HiRes 'time';
use Scalar::Util;
use Storable;
use JSON;

################################################################################

sub loading_log (@) {

	$ENV {DIA_SILENT} or print STDERR @_;

}

################################################################################

sub check_constants {

	$| = 1;

	$Data::Dumper::Sortkeys = 1;

	$SIG {__DIE__} = \&Carp::confess;

	our %INC_FRESH = ();
	our %INC_FRESH_BY_PATH = ();

}

################################################################################

sub check_version_by_git_files {

	require Compress::Raw::Zlib or return;

	-d (my $dir = "$preconf->{core_path}/.git") or return undef;

	open (H, "$dir/HEAD") or return undef;
	
	my $head = <H>; close H;
	
	$head =~ /ref:\s*([\w\/]+)/ or return undef;
	
	open (H, "$dir/$1") or return undef;
	
	$head = <H>; close H;
	
	$head =~ /^([a-f\d]{2})([a-f\d]{5})([a-f\d]{33})/ or return undef;
	
	my $tag = "$1$2";
	
	my $fn = "$dir/objects/$1/$2$3";
	
	open (H, $fn) or return undef;
	
	my $zipped;
	
	read (H, $zipped, -s $fn);
	
	close (H);
	
	length $zipped or return undef;
	
	my ($i, $status) = new Compress::Raw::Zlib::Inflate ();

	$status and return undef;

	$status = $i -> inflate ($zipped, my $src, 1);
	
	foreach (split /\n/, $src) {
	
		/committer.*?(\d+) ([\+\-])(\d{4})$/ or next;
		
		my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime ($1);
		
		return sprintf ("%02d.%02d.%02d.%s", $year - 100, $mon + 1, $mday, $tag);

	}

}

################################################################################

sub check_version_by_git {

	my $cwd = getcwd ();

	chdir $preconf -> {core_path};
	
	my $head = `git show HEAD --abbrev-commit --pretty=medium`;
	
	chdir $cwd;
	
	$head =~ /^commit (\w+).+Date\:\s+\S+\s+(\S+)\s+(\d+)\s[\d\:]+\s(\d+)/sm or return check_version_by_git_files ();
	
        return sprintf ("%02d.%02d.%02d.%s", 
        	$4 - 2000,
        	1 + (index ('JanFebMarAprMayJunJulAugSepOctNovDec', $2) / 3),
        	$3,
        	$1,
        );

}

################################################################################

sub check_version {
	
	use File::Spec;

	my $dir = File::Spec -> rel2abs (__FILE__);
		
	$dir =~ s{Dia.pm}{};
	
	$dir =~ y{\\}{/};
	
	$preconf -> {core_path} = $dir;

	require Date::Calc;

	return if $Dia::VERSION ||= $ENV {DIA_BANNER_PRINTED};
	
	my ($year) = Date::Calc::Today ();
	
	eval {require Dia::Version};
	
	$Dia::VERSION ||= check_version_by_git ();
	
	$Dia::VERSION ||= 'UNKNOWN (please write some Dia::Version module)';
	
	my $year;
	
	if ($Dia::VERSION =~ /^(\d\d)\.\d\d.\d\d/) {
	
		$year = '20' . $1;
	
	}
	else {

		($year) = Date::Calc::Today ();

	}
	
	my $length = 23 + length $Dia::VERSION;
	
	$length > 49 or $length = 49;
	
	my $bar = '-' x $length;

	loading_log <<EOT;

 $bar

 *****     *    Dia.pm
     *    *
     *   *
 ********       Version $Dia::VERSION
     * *
     **
 *****          Copyright (c) 2002-$year by Dia
 
 $bar

EOT

	$ENV {DIA_BANNER_PRINTED} = $Dia::VERSION;

}

################################################################################

sub check_web_server_apache {

	return if $preconf -> {use_cgi};
	
	my $module = 'Apache';

	$module .= 2 if $ENV {MOD_PERL_API_VERSION} >= 2;
		
	$module .= '::Request';

	loading_log "\n  mod_perl detected, checking for $module... ";

	my $version = 
		$ENV {MOD_PERL_API_VERSION} >= 2                 ? 2   :
		$ENV {MOD_PERL}              =~ m{mod_perl/1.99} ? 199 :
	                                                           1
	;

	eval "require Dia::Content::HTTP::API::ModPerl$version";

	if ($@) {

		$preconf -> {use_cgi} = 1;		
		loading_log "not found; falling back to CGI :-(\n";		
		return;

	}

}

################################################################################

sub check_web_server {

	loading_log " check_web_server... ";
	
	$ENV {MOD_PERL} or $ENV {MOD_PERL_API_VERSION} or $preconf -> {use_cgi} ||= 1;

	check_web_server_apache ();

	if ($preconf -> {use_cgi}) {
	
		eval "require Dia::Content::HTTP::API::CGISimple";
		
		if ($@) {

			loading_log " CGI::Simple is not installed... ";

			eval "require Dia::Content::HTTP::API::CGI";

		}		
		
	}
		
}

################################################################################

sub start_loading_logging {

	loading_log "\nLoading {\n" . (join ",\n", map {"\t$_"} @$PACKAGE_ROOT) . "\n} => " . __PACKAGE__ . "...\n";

}

################################################################################

sub finish_loading_logging {

	loading_log "Loading " . __PACKAGE__ . " is over.\n\n";

}

################################################################################

sub check_module_uri_escape {
	
	loading_log " check_module_uri_escape............. ";

	eval 'use URI::Escape::XS qw(uri_escape uri_unescape)';

	if ($@) {
	
		eval 'use URI::Escape qw(uri_escape uri_unescape); sub uri_escape {URI::Escape::uri_escape_utf8 (@_)}';
		
		die $@ if $@;

		loading_log "URI::Escape $URI::Escape::VERSION ok. [URI::Escape::XS SUGGESTED]\n";
		
	}
	else {
	
		loading_log "URI::Escape::XS $URI::Escape::XS::VERSION ok.\n";

	}
	
}

################################################################################

sub check_module_memory {

	loading_log " check_module_memory................. ";

	require Dia::Content::Memory;

}

################################################################################

sub check_module_mail {

	loading_log " check_module_mail................... ";

	if ($preconf -> {mail}) { 
		
		require Dia::Content::Mail;

		loading_log "$preconf->{mail}->{host}, ok.\n";
		
	} 
	else { 
		
		eval 'sub send_mail {warn "Mail parameters are not set.\n" }';

		loading_log "no mail, ok.\n";
		
	}

}

################################################################################

sub check_module_queries {

	loading_log " check_module_queries................ ";

	if ($conf -> {core_store_table_order}) { 
		
		require Dia::Content::Queries;

		loading_log "stored queries enabled, ok.\n";

	} 
	else { 
		
		eval 'sub fix___query {}; sub check___query {}';
	
		loading_log "no stored queries, ok.\n";

	}

}

#############################################################################

sub darn ($) {warn Dumper ($_[0]); return $_[0]}

################################################################################

BEGIN {

	foreach (grep {/^Dia/} keys %INC) { delete $INC {$_} }
	
	check_constants             ();
	check_version               ();
	
	loading_log                 (" Running on Perl $^V ($^X)\n");

	start_loading_logging       ();

	check_web_server            (); 
	
	require "Dia/$_.pm" foreach qw (Content SQL GenericApplication/Config);

	require_config              ();
	
	&{"check_module_$_"}        () foreach sort grep {!/^_/} keys %{$conf -> {core_modules}};

	finish_loading_logging      ();

}

package Dia;

1;

__END__

################################################################################

=head1 NAME

Dia - a non-OO MVC.

=head1 WARNING

We totally neglect most of so called 'good style' conventions. We do find it really awkward and quite useless.

=head1 APOLOGIES

The project is deeply documented (L<http://eludia.ru/wiki>), but, sorry, in Russian only.

=head1 AUTHORS

Dmitry Ovsyanko

Pavel Kudryavtzev

Roman Lobzin

Vadim Stepanov