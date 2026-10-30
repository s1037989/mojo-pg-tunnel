# Validation

Validated with Perl 5.38.2, Mojolicious 9.35, Mojo::Pg 4.27,
DBD::Pg 3.18.0, and PostgreSQL 16.15 in an isolated local test environment.

```
t/01-protocol.t .. ok
t/02-postgres.t .. ok
All tests successful.
Files=2, Tests=75
Result: PASS
```

Both app scripts and examples/query.pl also pass Perl syntax checks.

Coverage includes bearer authentication for both transports, rejection of
browser origins, scalar/null binds, SQL lexical validation, Unicode, HTTP
commit, oversized-result rollback, transaction connection affinity, isolation,
WebSocket commit, automatic rollback, SQLSTATE errors, failed-transaction
handling, idle and in-flight disconnect rollback, statement timeouts, capacity
release, operation serialization, large allowed WebSocket responses, and the
client app's four routes.

The checks use local plain HTTP/WebSocket with explicit insecure-development
opt-in. A deployment-specific TLS certificate chain, reverse proxy, external
network behavior, worker sizing, PostgreSQL permissions, and performance/load
testing need validation in the target environment. CPAN dependencies are not
included in the archive.
