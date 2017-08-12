#!/usr/bin/env perl
use 5.10.1;
use strict;
use warnings;
use Test::More 1.302;
use Test::Selenium::Remote::Driver;

plan skip_all => "these tests only run in CI" unless $ENV{CI};

my @require_env = qw(
    TWD_BASE
    TWD_HOST
    TWD_PORT
    BZ_BASE_URL
);

my $sel = Test::Selenium::Remote::Driver->new(
    base_url => $ENV{BZ_BASE_URL}
);

$sel->get("/login");
$sel->title_is("Log in to Bugzilla");
$sel->find_element('//input[@name="Bugzilla_login"]', 'xpath')->click();
$sel->send_keys_to_active_element("vagrant\@bmo-web.vm");
$sel->find_element('//input[@name="Bugzilla_password"]', 'xpath')->click();
$sel->send_keys_to_active_element("vagrant01!");
$sel->find_element('//input[@name="GoAheadAndLogIn"]', 'xpath')->submit();
$sel->title_is("Bugzilla Main Page");

done_testing;
