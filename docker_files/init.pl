#!/usr/bin/perl
use 5.10.1;
use strict;
use warnings;
use lib qw(/app /opt/bmo/local/lib/perl5);
use Bugzilla::Install::Localconfig ();
use Bugzilla::Install::Util qw(install_string);
use DBI;
use Data::Dumper;
use LWP::Simple qw(get);
use English qw($EUID);
use Getopt::Long qw(:config gnu_getopt);
use File::Copy::Recursive;

my $cmd = shift @ARGV;
my $func = __PACKAGE__->can("cmd_$cmd") // sub { system_verbose($cmd, @ARGV) };

check_env();
check_localconfig();
write_localconfig( localconfig_from_env() );
$func->();

sub cmd_httpd  {
    check_data_dir();
    wait_for_db();
    system_verbose( '/usr/sbin/httpd', '-DFOREGROUND', '-f', '/opt/bmo/httpd/httpd.conf' );
}

sub cmd_load_test_data {
    wait_for_db();

    system_verbose( 'perl', 'checksetup.pl', '--no-template', "/app/docker_files/checksetup_answers.txt" );
    system_verbose( 'perl', 'scripts/generate_bmo_data.pl', '--user-pref', 'ui_experiments=off' );
    chdir('/app/qa/config');
    warn 'chdir(/app/qa/config)\n';
    system_verbose('perl', 'generate_test_data.pl');
}

sub cmd_test_heartbeat {
    my $conf = require $ENV{BZ_QA_CONF_FILE};
    wait_for_httpd($conf->{browser_url});
    my $heartbeat = get("$conf->{browser_url}/__heartbeat__");
    warn "$heartbeat\n";
    if ($heartbeat =~ /Bugzilla OK/) {
        exit 0;
    }
    else {
        exit 1;
    }
}

sub cmd_test_webservices {
    my $conf = require $ENV{BZ_QA_CONF_FILE};

    check_data_dir();
    wait_for_db();
    wait_for_httpd($conf->{browser_url});

    chdir('/app/qa/t');
    system_verbose( 'prove', '-f', '-I/app', '-I/app/local/lib/perl5',
        glob('webservice_*.t') );
}

sub cmd_shell   { system_verbose( 'bash', '-l' ); }

sub cmd_version { system_verbose( 'cat', '/app/version.json' ); }

sub system_verbose {
    warn "@_\n";
    system(@_) and die "exited badly: $?";
}

sub wait_for_db {
    die "/app/localconfig is missing\n" unless -f "/app/localconfig";

    my $c = Bugzilla::Install::Localconfig::read_localconfig();
    my $dsn = "dbi:mysql:database=$c->{db_name};host=$c->{db_host}";
    my $dbh;
    foreach (1..12) {
        warn "checking database...\n" if $_ > 1;
        $dbh = DBI->connect(
            $dsn,
            $c->{db_user},
            $c->{db_pass}, 
            { RaiseError => 0, PrintError => 0 }
        );
        last if $dbh;
        warn "database not available, waiting...\n";
        sleep(10);
    }
    die "unable to connect to $dsn as $c->{db_user}\n" unless $dbh;
}

sub wait_for_httpd {
    my ($url) = @_;
    my $ok = 0;
    foreach (1..12) {
        warn "checking if httpd is up...\n" if $_ > 1;
        my $resp = get("$url/__lbheartbeat__");
        if ($resp =~ /^\s+httpd OK/) {
            $ok = 1;
            last;
        }
        warn "httpd doesn't seem to be up at $url. waiting...\n";
        sleep(10);
    }
    die "unable to connect to httpd at $url\n" unless $ok;
}

sub localconfig_from_env {
    my %localconfig = ( webservergroup => 'app' );

    my %override = (
        'inbound_proxies' => 1,
        'shadowdb'        => 1,
        'shadowdbhost'    => 1,
        'shadowdbport'    => 1,
        'shadowdbsock'    => 1
    );

    foreach my $key ( keys %ENV ) {
        if ( $key =~ /^BMO_(.+)$/ ) {
            my $name = $1;
            if ( $override{$name} ) {
                $localconfig{param_override}{$name} = delete $ENV{$key};
            }
            else {
                $localconfig{$name} = delete $ENV{$key};
            }
        }
    }

    return \%localconfig;
}

sub write_localconfig {
    my ($localconfig) = @_;
    no warnings 'once';

    foreach my $var (Bugzilla::Install::Localconfig::LOCALCONFIG_VARS) {
        my $name = $var->{name};
        my $value = $localconfig->{$name};
        if (!defined $value) {
            $var->{default} = &{$var->{default}} if ref($var->{default}) eq 'CODE';
            $localconfig->{$name} = $var->{default};
        }
    }

    my $filename = "/app/localconfig";

    # Ensure output is sorted and deterministic
    local $Data::Dumper::Sortkeys = 1;

    # Re-write localconfig
    open my $fh, ">:utf8", $filename or die "$filename: $!";
    foreach my $var (Bugzilla::Install::Localconfig::LOCALCONFIG_VARS) {
        my $name = $var->{name};
        my $desc = install_string("localconfig_$name", { root => Bugzilla::Install::Localconfig::ROOT_USER });
        chomp($desc);
        # Make the description into a comment.
        $desc =~ s/^/# /mg;
        print $fh $desc, "\n",
                  Data::Dumper->Dump([$localconfig->{$name}],
                                     ["*$name"]), "\n";
   }
   close $fh;
}

sub check_localconfig {
    die "/app/localconfig should not exist\n" if -f "/app/localconfig";
}


sub check_data_dir {
    die "/app/data must be writable by effective uid ($EUID)" unless -w "/app/data";
    die "/app/data/params must exist" unless -f "/app/data/params";
}

sub check_env {
    my @require_env = qw(
        BMO_db_host
        BMO_db_name
        BMO_db_user
        BMO_db_pass
        BMO_memcached_namespace
        BMO_memcached_servers
        BZ_QA_CONF_FILE
    );
    my @missing_env = grep { not exists $ENV{$_} } @require_env;
    if (@missing_env) {
        die "Missing required environmental variables: ", join(", ", @missing_env);
    }
}
