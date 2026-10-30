# Mojolicious PostgreSQL tunnel

Two Perl apps and a reusable promise-based client. The client app needs HTTP(S)
access to the gateway. Only the gateway needs PostgreSQL network access and a
database password.

Your Mojolicious app sends SQL through HTTPS/WSS to the gateway, which executes
it through its direct PostgreSQL connection.

This is an application-level SQL RPC interface. It does not carry PostgreSQL's
binary wire protocol and cannot be used as a DBI DSN, Mojo::Pg connection string,
or psql endpoint. Your application uses PgTunnel::Client instead of Mojo::Pg for
the remote operations. The gateway uses Mojo::Pg internally.

## Included files

| Path | Purpose |
| --- | --- |
| script/gateway | App with direct PostgreSQL access |
| script/client | Mojolicious::Lite example client app |
| lib/PgTunnel/Client.pm | HTTP queries and transaction wrapper |
| lib/PgTunnel/Session.pm | WebSocket transaction session |
| lib/PgTunnel/Results.pm | Small Mojo::Pg-style results interface |
| examples/query.pl | Standalone Perl client example |
| t/01-protocol.t | Authentication, protocol and SQL validation checks |
| t/02-postgres.t | Real database and both-app integration checks |

## Install

Perl 5.20+ is required. The examples also run on Perl 5.40/5.42.
From the extracted project directory on the gateway:

```sh
cpanm --installdeps .
```

DBD::Pg needs libpq and PostgreSQL development headers when built from source;
the HTTPS client needs OpenSSL development headers when its SSL dependencies
are built from source. OS packages providing these CPAN modules are also fine.

The client host needs only Mojolicious and IO::Socket::SSL, plus this project's
lib directory. It does not need Mojo::Pg, DBI, DBD::Pg, or libpq:

```sh
cpanm Mojolicious IO::Socket::SSL
```

For an offline installation, stage these distributions and their transitive
dependencies in your local CPAN mirror, then install using that mirror.
Third-party dependencies are not bundled in this archive.

## Run locally

Create a random shared token once, then place the same value in both apps'
environments. On Linux this Perl command prints a suitable token:

```perl
perl -e 'open my $fh, "<:raw", "/dev/urandom" or die $!; read($fh, my $bytes, 32) == 32 or die "short read"; print unpack("H*", $bytes), "\n";'
```

Terminal 1, on the gateway host, using a PostgreSQL database and login that
already exist:

```sh
export PG_TUNNEL_TOKEN='paste-the-generated-token-here'
export PG_TUNNEL_DSN='postgresql://app_user:password@127.0.0.1/app_db?connect_timeout=5'
perl script/gateway daemon -l http://127.0.0.1:3001
```

Percent-encode reserved URL characters in usernames/passwords. For remote
PostgreSQL, configure its TLS verification through the libpq connection
parameters, for example sslmode=verify-full and sslrootcert.

Terminal 2, on the client host (same host for this local demo):

```sh
export PG_TUNNEL_TOKEN='paste-the-same-generated-token-here'
export PG_TUNNEL_URL='http://127.0.0.1:3001'
export PG_TUNNEL_ALLOW_INSECURE=1
perl script/client daemon -l http://127.0.0.1:3000
```

Open http://127.0.0.1:3000/ and try these routes:

| Route | Behavior |
| --- | --- |
| GET /time | HTTP query for database time and name |
| GET /echo?value=hello | HTTP query using a bound parameter |
| GET /transaction-demo | WebSocket transaction creating, filling and reading a temporary table |

Or, with the same client environment, run `perl examples/query.pl`.
The transaction demo needs TEMP permission on the database. It leaves no
permanent table behind. The sample client intentionally exposes only fixed SQL
operations; it has no browser-accessible arbitrary-SQL route.

## Use from your Mojolicious app

The HTTP API accepts SQL and bind values separately. Use `?` placeholders as
you would with Mojo::Pg; bind values are never interpolated into SQL.

```perl
use PgTunnel::Client;

helper remote_db => sub {
  state $db = PgTunnel::Client->new(
    url => 'https://db-gateway.example.test',
    token => $ENV{PG_TUNNEL_TOKEN});
};

get '/people/:id' => sub ($c) {
  $c->render_later;
  $c->remote_db->query_p(
    'SELECT id, name FROM people WHERE id = ?', $c->param('id')
  )->then(sub ($result) {
    my $person = $result->hash;
    return $c->render(status => 404, json => {error => 'Not found'}) unless $person;
    $c->render(json => $person);
  })->catch(sub ($err) {
    $c->app->log->warn("$err");
    $c->render(status => 502, json => {error => 'Database unavailable'});
  });
};
```

Use `Mojolicious::Lite -signatures` in the containing app, as script/client does.
Result methods are `columns`, `array`, `arrays`, `hash`, `hashes`, `rows`, and
`affected_rows`. Fetch methods consume rows. `arrays`/`hashes` return
Mojo::Collection objects. Array results retain duplicate column names; hash
results need unique column aliases. This is a small interface, not a full
Mojo::Pg::Results or SQL::Abstract implementation.

## Transactions over WebSockets

Each `begin_p` opens a separate WebSocket. The gateway starts a transaction and
holds one dedicated database connection for that session. Await each operation
before sending the next. Separate sessions and HTTP requests can run
concurrently.

Prefer the automatic wrapper. Return the entire promise chain from its callback:

```perl
$db->transaction_p(sub ($tx) {
  return $tx->query_p(
    'UPDATE accounts SET balance = balance - ? WHERE id = ?', 10, 100
  )->then(sub {
    return $tx->query_p(
      'UPDATE accounts SET balance = balance + ? WHERE id = ?', 10, 200);
  });
})->then(sub { say 'Committed' })
  ->catch(sub ($err) { warn "$err\n" });
```

The wrapper commits after the returned promise resolves and attempts rollback
if it rejects or the callback throws. Its resolved values are the callback's
values. A lower-level interface is also available:

```perl
$db->begin_p->then(sub ($tx) {
  return $tx->query_p('SELECT now()::text AS value')->then(sub ($r) {
    my $value = $r->hash->{value};
    return $tx->commit_p->then(sub { return $value });
  })->catch(sub ($err) {
    return $tx->rollback_p->catch(sub { return undef })->then(sub { die $err });
  });
});
```

Keep the session object alive while using it. `close`, dropping the session,
socket loss, and gateway process death close its database connection; PostgreSQL
rolls back any uncommitted work. If a query is in flight at disconnect, the
gateway waits for its bounded completion before disconnecting. An SQL/result
error marks the transaction failed: only rollback is then allowed. Savepoint
recovery is not implemented.

**A lost response can mean an unknown outcome.** A COMMIT might succeed before
its reply is lost. The same applies to an HTTP query whose response is lost
after commit. Neither transport retries queries, reconnects sessions, or replays
writes. For retryable business operations, use a unique operation key stored
with the change and an application-specific reconciliation query. Rollback
cannot undo a commit that has already happened.

HTTP queries also run in an explicit transaction. The gateway validates the
result before committing, so a result-limit error rolls back an ordinary write.
PostgreSQL sequence increments and external effects of database functions are
not transactional. HTTP connections close after each call; session state is
never reused between callers. A WebSocket saves connection setup overhead for
multi-query operations. PgBouncer can reduce backend connection overhead if
needed.

## Authentication and deployment

The shared bearer token is sent only as the Authorization header, for HTTP and
the WebSocket upgrade. Keep it in server-side configuration. This demo has one
service identity mapped to one PostgreSQL role; it does not impersonate each
browser user. Implement user authorization in your client app.

Use HTTPS/WSS across hosts. The Perl client refuses plain HTTP unless
`allow_insecure => 1` is explicitly set (the demo app uses
PG_TUNNEL_ALLOW_INSECURE). Certificate verification stays enabled. Use a trusted
internal CA with IO::Socket::SSL's CA configuration for private certificates.
Do not disable verification.

The gateway's bearer token grants the SQL powers of its configured database
role. Use a dedicated, least-privilege login, a private network/firewall, and
TLS. The SQL lexer is a protocol check, not a sandbox: functions invoked by
trusted SQL can still change data, settings, or resource use. Use predefined
named queries or stored procedures instead if callers are untrusted. Query
timeouts are operational defaults, not tamperproof limits for unrestricted SQL
callers. No SQL text, bind values or token is logged by the app; PostgreSQL and
your proxy have their own logging policies.

For TLS termination at Nginx, the relevant location settings are:

```nginx
location /v1/ {
    proxy_pass http://127.0.0.1:3001;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Authorization $http_authorization;
    proxy_read_timeout 90s;
    proxy_buffering off;
    client_max_body_size 64k;
}
```

Put this location inside your existing TLS virtual host. WebSocket support must
be enabled across the complete proxy path. Launch the gateway with Hypnotoad or
another supervised Mojolicious server for deployment; size database capacity
for worker count times PG_TUNNEL_MAX_ACTIVE. Database connection establishment
and the short initialization statements are synchronous in Mojo::Pg; SQL query
execution uses query_p. Keep the database nearby, use connect_timeout, and size
workers accordingly.

The browser Origin header is rejected by default because this gateway is for
server-to-server use. CORS is not enabled. Both demo daemons bind to loopback in
the instructions above. Protect any client app exposed to users with your own
login and authorization.

## Limits and supported SQL/data

| Gateway setting | Default |
| --- | --- |
| PG_TUNNEL_STATEMENT_MS | 30000 ms per statement |
| PG_TUNNEL_IDLE_MS | 60000 ms idle in a transaction |
| PG_TUNNEL_MAX_ACTIVE | 20 HTTP/WS operations or sessions per worker |
| PG_TUNNEL_MAX_ROWS | 1000 returned rows |
| PG_TUNNEL_MAX_BYTES | 1048576 encoded result bytes |
| HTTP request / inbound WebSocket message | 65536 bytes |
| Bind count / SQL character count | 1000 / 50000 |

Client defaults: 40-second operation timeout, 75-second WebSocket inactivity
timeout, 2 MiB response/message limit. Set operation timeout above the gateway
statement timeout. If increasing gateway result limits above 1 MiB, adjust the
client limits in Client.pm as well. A socket idle timeout closes the session;
keep transactions short and avoid waiting for user input inside a transaction.

SELECT/INSERT/UPDATE/DELETE/WITH/VALUES/SHOW/EXPLAIN and common transactional DDL
are accepted as one statement per call. Optional final semicolon, standard SQL
strings, E strings, dollar quotes and comments are supported. Use placeholders
for values. Transaction control is available only through the session methods.
SET/RESET, COPY, CALL/DO, PREPARE, SAVEPOINT, VACUUM, multi-statement scripts,
LISTEN/NOTIFY subscriptions and PostgreSQL large-object operations are outside
this interface. Commands that PostgreSQL forbids inside a transaction, such as
CREATE DATABASE, will fail. Use direct database administration for these.

Bind values are scalars or undef (JSON null). For JSON/JSONB, pass encoded JSON
text and use `?::jsonb`; results remain JSON strings, without automatic expand.
Pass booleans as PostgreSQL-compatible strings or 1/0. For BYTEA, explicitly
encode/decode using hex or base64 in SQL; opaque binary transport is not part of
this JSON protocol. No server-side cursors or row streaming are implemented.

**The row/byte checks bound returned JSON, not libpq's internal memory.** libpq
buffers a query result before these checks run. Use LIMIT, keyset pagination,
bounded columns and appropriate database/proxy resource limits for large data.

## Protocol

HTTP: `POST /v1/query`, authenticated, with JSON:

```json
{"sql":"SELECT ?::integer AS answer","bind":[42]}
```

Success:

```json
{"ok":true,"result":{"columns":["answer"],"data":[[42]],"affected_rows":1}}
```

WebSocket: upgrade `/v1/transaction` with the same Authorization header. Send
`{"op":"start"}` after installing message handlers. The server executes BEGIN
and replies `{"ok":true,"ready":true}`. The explicit start avoids an upgrade
race where a ready notification could arrive before the client's listeners.

Then send `{"id":1,"op":"query","sql":"SELECT 42 AS answer","bind":[]}`.
The result has the same shape as HTTP, plus the matching id. Finish with
`{"id":2,"op":"commit"}` or `{"id":2,"op":"rollback"}`; the server
acknowledges with `ok:true` and closes the WebSocket. One request at a time.

Errors contain `ok:false` and `error:{code,message,sqlstate?}`. WebSocket errors
also carry the matching id when the request was valid. PgTunnel::Error exposes
code, message, sqlstate and (for HTTP errors) status. Raw database error text is
not sent back. SQL/result errors use HTTP 400, capacity exhaustion 503,
authentication failure 401 and Origin rejection 403.

## Test

Protocol checks, no database required:

```sh
prove -l t/01-protocol.t
```

Integration checks create and drop an isolated temporary test table in the
specified disposable database. They also create session-local temporary tables:

```sh
TEST_PG_DSN='postgresql://test_user:password@127.0.0.1/test_db' prove -l t
```

Never point integration checks at a production database. Without TEST_PG_DSN,
the database suite skips. Dependencies are installed separately as above.

API references: [Mojo::Pg::Database](https://docs.mojolicious.org/Mojo/Pg/Database),
[Mojo::UserAgent](https://docs.mojolicious.org/Mojo/UserAgent),
[DBD::Pg](https://metacpan.org/pod/DBD::Pg).
