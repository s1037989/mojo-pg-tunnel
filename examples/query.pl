#!/usr/bin/env perl
use FindBin;
use lib "$FindBin::Bin/../lib";
use Mojo::Base -strict, -signatures;
use PgTunnel::Client;

my $db = PgTunnel::Client->new(
  url => $ENV{PG_TUNNEL_URL} // 'https://gateway.example.test',
  token => $ENV{PG_TUNNEL_TOKEN} // die('PG_TUNNEL_TOKEN is required'),
  allow_insecure => $ENV{PG_TUNNEL_ALLOW_INSECURE} // 0);
$db->query_p('SELECT ?::text AS greeting, now()::text AS server_time', 'Hello through HTTP')
  ->then(sub ($r) { say $r->hashes->first->{greeting} })
  ->catch(sub ($err) { die "$err\n" })->wait;

$db->transaction_p(sub ($tx) {
  return $tx->query_p('CREATE TEMP TABLE demo (value text) ON COMMIT DROP')
    ->then(sub { $tx->query_p('INSERT INTO demo VALUES (?)', 'Hello through WebSocket') })
    ->then(sub { $tx->query_p('SELECT value FROM demo') })
    ->then(sub ($r) { $r->hash->{value} });
})->then(sub ($value) { say $value })
  ->catch(sub ($err) { die "$err\n" })->wait;
