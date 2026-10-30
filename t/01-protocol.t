use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use PgTunnel::Gateway;
use PgTunnel::Client;
use PgTunnel::SQL;

local $ENV{PG_TUNNEL_TOKEN} = 'a' x 48;
my $app = PgTunnel::Gateway->new;
$app->log->level('error');
my $t = Test::Mojo->new($app);
$t->post_ok('/v1/query' => json => {sql => 'SELECT 1', bind => []})->status_is(401);
my $denied;
$t->ua->websocket_p('/v1/transaction')->then(sub { $denied = 0 })
  ->catch(sub { $denied = 1 })->wait;
ok($denied, 'unauthenticated WebSocket handshake rejected');
my $h = {Authorization => 'Bearer ' . $ENV{PG_TUNNEL_TOKEN}};
$t->post_ok('/v1/query' => {%$h, Origin => 'https://example.test'} => json => {})->status_is(403);
$t->post_ok('/v1/query' => $h => json => {sql => 'SELECT 1', bind => [{}]})
  ->status_is(400)->json_is('/error/code', 'invalid_bind');
$t->post_ok('/v1/query' => $h => json => {sql => 'COMMIT', bind => []})
  ->status_is(400)->json_is('/error/code', 'unsupported_sql');
for my $sql ('SELECT 1', q{SELECT ';' AS x; -- trailing}, q{SELECT E'foo\'bar'},
  q{SELECT $$a;b$$}, q{SELECT $tag$a;b$tag$}, q{/* outer /* inner */ end */ SELECT 1},
  q{SELECT "a;b" FROM t}, q{WITH x AS (SELECT 1) SELECT * FROM x}) {
  ok(eval { PgTunnel::SQL::validate($sql) }, "accepted: $sql") or diag $@;
}
for my $sql ('BEGIN', 'ROLLBACK', 'COPY x TO STDOUT', 'SELECT 1; SELECT 2',
  'SELECT 1;;', q{SELECT 'unclosed}, 'SELECT 1 /*', 'SELECT $$unfinished',
  'SET standard_conforming_strings=off') {
  ok(!eval { PgTunnel::SQL::validate($sql) }, "rejected: $sql");
}
my $r = PgTunnel::Results->new(columns => ['x', 'y'], data => [[1, undef], [2, 'two']], affected_rows => 2);
is_deeply($r->hash, {x => 1, y => undef}, 'null preserved');
is_deeply($r->arrays->to_array, [[2, 'two']], 'remaining results');
my $client = PgTunnel::Client->new(token => 'x');
ok(!eval { $client->_url('/v1/query') }, 'insecure transport requires explicit opt-in');
done_testing;
