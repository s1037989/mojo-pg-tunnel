use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use Mojo::Pg;
use PgTunnel::Gateway;
use PgTunnel::Client;
use FindBin;
use Mojo::Server;

plan skip_all => 'Set TEST_PG_DSN to a disposable PostgreSQL database' unless $ENV{TEST_PG_DSN};
local $ENV{PG_TUNNEL_DSN} = $ENV{TEST_PG_DSN};
local $ENV{PG_TUNNEL_TOKEN} = 'integration-test-token-' . ('x' x 32);
local $ENV{PG_TUNNEL_STATEMENT_MS} = 300;
local $ENV{PG_TUNNEL_MAX_ROWS} = 3;
local $ENV{PG_TUNNEL_MAX_BYTES} = 1024;
my $admin = Mojo::Pg->new($ENV{TEST_PG_DSN});
my $table = 'pg_tunnel_test_' . $$ . '_' . int(rand 1_000_000);
$admin->db->query("CREATE TABLE $table (id integer PRIMARY KEY, value text)");
END { eval { $admin->db->query("DROP TABLE IF EXISTS $table") } if $admin && $table }
my $app = PgTunnel::Gateway->new;
$app->log->level('error');
my $t = Test::Mojo->new($app);
my $client = PgTunnel::Client->new(url => $t->ua->server->url->to_string,
  token => $ENV{PG_TUNNEL_TOKEN}, ua => $t->ua, allow_insecure => 1, timeout => 3);
sub await ($promise) {
  my (@out, $error);
  $promise->then(sub { @out = @_ })->catch(sub ($e) { $error = $e })->wait;
  die $error if defined $error;
  return $out[0];
}
sub fails ($promise, $code) {
  my $error;
  $promise->catch(sub ($e) { $error = $e })->wait;
  ok(defined $error, "rejected: $code");
  is(eval { $error->code }, $code, 'error code') if ref $error;
  return $error;
}
my $r = await($client->query_p('SELECT ?::text AS value, ?::text AS missing', "quote'; semicolon; \x{2665}", undef));
is_deeply($r->hash, {value => "quote'; semicolon; \x{2665}", missing => undef}, 'binds, Unicode and null round trip');
$r = await($client->query_p("INSERT INTO $table VALUES (?, ?) RETURNING id", 1, 'http'));
is($r->hash->{id}, 1, 'HTTP returning');
is($admin->db->query("SELECT count(*) FROM $table")->array->[0], 1, 'HTTP query committed');
fails($client->query_p('SELECT generate_series(1,4)'), 'result_limit');
fails($client->query_p(q{SELECT repeat('x', 2000)}), 'result_limit');
fails($client->query_p("INSERT INTO $table SELECT generate_series(10,13), 'large' RETURNING id"), 'result_limit');
is($admin->db->query("SELECT count(*) FROM $table WHERE id >= 10")->array->[0], 0, 'oversized HTTP write rolled back');
my $tx = await($client->begin_p);
my $pid = await($tx->query_p('SELECT pg_backend_pid() AS pid'))->hash->{pid};
await($tx->query_p("INSERT INTO $table VALUES (?, ?)", 2, 'websocket'));
is(await($tx->query_p('SELECT pg_backend_pid() AS pid'))->hash->{pid}, $pid, 'transaction retains backend');
is($admin->db->query("SELECT count(*) FROM $table WHERE id=2")->array->[0], 0, 'uncommitted write isolated');
await($tx->commit_p);
is($admin->db->query("SELECT count(*) FROM $table WHERE id=2")->array->[0], 1, 'WebSocket commit durable');
my $row = await($client->transaction_p(sub ($s) {
  $s->query_p('CREATE TEMP TABLE affinity (v text) ON COMMIT DROP')
    ->then(sub { $s->query_p('INSERT INTO affinity VALUES (?)', 'temporary') })
    ->then(sub { $s->query_p('SELECT v FROM affinity') })
    ->then(sub ($r) { $r->hash });
}));
is_deeply($row, {v => 'temporary'}, 'transaction wrapper returns callback value');
my $rolled_back;
$client->transaction_p(sub ($s) {
  $s->query_p("INSERT INTO $table VALUES (3, 'rollback')")->then(sub { die "intentional failure\n" });
})->catch(sub ($e) { $rolled_back = "$e" })->wait;
like($rolled_back, qr/intentional failure/, 'callback failure preserved');
is($admin->db->query("SELECT count(*) FROM $table WHERE id=3")->array->[0], 0, 'wrapper rolled back');
$tx = await($client->begin_p);
my $err = fails($tx->query_p("INSERT INTO $table VALUES (1, 'duplicate')"), 'database_error');
is($err->sqlstate, '23505', 'SQLSTATE preserved');
fails($tx->commit_p, 'transaction_failed');
await($tx->rollback_p);
$tx = await($client->begin_p);
await($tx->query_p("INSERT INTO $table VALUES (4, 'disconnect')"));
$tx->close;
# Run the loop until the server sees the WebSocket close, then observe externally.
my $barrier = Mojo::Promise->new;
Mojo::IOLoop->timer(0.05 => sub { $barrier->resolve }); await($barrier);
is($admin->db->query("SELECT count(*) FROM $table WHERE id=4")->array->[0], 0, 'disconnect rolled back');
fails($client->query_p('SELECT pg_sleep(1)'), 'database_error');
is(await($client->query_p('SELECT 42 AS answer'))->hash->{answer}, 42, 'gateway recovers after timeout');
$app->max_active(1);
$tx = await($client->begin_p);
fails($client->query_p('SELECT 1'), 'busy');
await($tx->rollback_p);
await($client->query_p('SELECT 1'));
is($app->_active, 0, 'capacity released after transaction');
$app->max_active(20);
# Verify that a second operation is rejected locally while the first is pending.
$tx = await($client->begin_p);
my $slow = $tx->query_p('SELECT pg_sleep(0.05)');
my $concurrency_error;
$tx->query_p('SELECT 1')->catch(sub ($e) { $concurrency_error = "$e" })->wait;
like($concurrency_error, qr/previous transaction operation/, 'session operations are serialized');
await($slow); await($tx->rollback_p);
# Results bigger than Mojo's default 256 KiB WebSocket receive limit.
$app->max_bytes(1048576);
$tx = await($client->begin_p);
is(length(await($tx->query_p(q{SELECT repeat('z', 300000) AS value}))->hash->{value}),
  300000, 'large allowed WebSocket response received');
await($tx->rollback_p);
# Close while SQL is active: wait for completion, then discard the connection.
$tx = await($client->begin_p);
my $inflight = $tx->query_p("INSERT INTO $table SELECT 5, 'inflight' FROM pg_sleep(0.1)");
my $lost;
$inflight->catch(sub ($e) { $lost = $e });
$tx->close;
my $settled = Mojo::Promise->new;
Mojo::IOLoop->timer(0.2 => sub { $settled->resolve }); await($settled);
is(eval { $lost->code }, 'connection_lost', 'in-flight operation rejects on close');
is($admin->db->query("SELECT count(*) FROM $table WHERE id=5")->array->[0], 0, 'in-flight disconnect rolled back');
is($app->_active, 0, 'in-flight disconnect releases capacity');
local $ENV{PG_TUNNEL_URL} = $client->url;
local $ENV{PG_TUNNEL_ALLOW_INSECURE} = 1;
my $demo = Test::Mojo->new(Mojo::Server->new->load_app("$FindBin::Bin/../script/client"));
$demo->app->log->level('error');
$demo->get_ok('/')->status_is(200);
$demo->get_ok('/time')->status_is(200)->json_has('/server_time');
$demo->get_ok('/echo?value=hello')->status_is(200)->json_is('/echo', 'hello');
$demo->get_ok('/transaction-demo')->status_is(200)->json_is('/value', 'same connection');
done_testing;
