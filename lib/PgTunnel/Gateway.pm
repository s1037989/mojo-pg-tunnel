package PgTunnel::Gateway;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Pg;
use Mojo::Promise;
use Mojo::JSON qw(decode_json encode_json true false);
use Mojo::Util qw(secure_compare);
use Digest::SHA qw(sha256_hex);
use PgTunnel::Error;
use PgTunnel::SQL;

has pg => sub ($self) {
  my $dsn = $ENV{PG_TUNNEL_DSN} // die 'PG_TUNNEL_DSN is required';
  my $pg = Mojo::Pg->new($dsn);
  $pg->on(connection => sub ($pg, $dbh) {
    $dbh->{private_mojo_no_reuse} = 1;
    $dbh->do('SET standard_conforming_strings = on');
    $dbh->do('SET statement_timeout = ' . $self->statement_ms);
    $dbh->do('SET idle_in_transaction_session_timeout = ' . $self->idle_ms);
  });
  return $pg;
};
has token => sub { $ENV{PG_TUNNEL_TOKEN} // '' };
has statement_ms => sub { $ENV{PG_TUNNEL_STATEMENT_MS} // 30000 };
has idle_ms => sub { $ENV{PG_TUNNEL_IDLE_MS} // 60000 };
has max_rows => sub { $ENV{PG_TUNNEL_MAX_ROWS} // 1000 };
has max_bytes => sub { $ENV{PG_TUNNEL_MAX_BYTES} // 1048576 };
has max_active => sub { $ENV{PG_TUNNEL_MAX_ACTIVE} // 20 };
has _active => 0;

sub startup ($self) {
  die 'PG_TUNNEL_TOKEN must be at least 32 characters' if length($self->token) < 32;
  for my $name (qw(statement_ms idle_ms max_rows max_bytes max_active)) {
    die "Invalid positive integer setting: $name" unless $self->$name =~ /^[1-9][0-9]*$/;
  }
  $self->max_request_size(65536);
  my $v1 = $self->routes->under('/v1')->to(cb => sub ($c) {
    # This is a server-to-server endpoint. Browsers must not receive this token.
    if (defined $c->req->headers->origin) {
      $c->render(status => 403, json => _err('origin_denied', 'Browser access is disabled'));
      return undef;
    }
    my $header = $c->req->headers->authorization // '';
    my ($token) = $header =~ /^Bearer ([^\s]+)$/;
    unless (defined $token && secure_compare(sha256_hex($token), sha256_hex($self->token))) {
      $c->res->headers->www_authenticate('Bearer');
      $c->render(status => 401, json => _err('unauthorized', 'Bearer token required'));
      return undef;
    }
    $c->res->headers->cache_control('no-store');
    return 1;
  });
  $v1->post('/query')->to(cb => sub ($c) { $self->_http($c) });
  $v1->websocket('/transaction')->to(cb => sub ($c) { $self->_ws($c) });
}
sub _err ($code, $message, $state = undef) {
  return {ok => false, error => {code => $code, message => $message,
    (defined $state && length $state ? (sqlstate => $state) : ())}};
}
sub _failure ($self, $err, $db = undef) {
  return _err($err->code, $err->message) if ref $err && eval { $err->isa('PgTunnel::Error') };
  my $state = $db ? eval { $db->dbh->state } : undef;
  $self->log->warn('Database operation failed' . ($state ? " (SQLSTATE $state)" : ''));
  return _err('database_error', 'Database operation failed', $state);
}
sub _validate ($self, $m) {
  die PgTunnel::Error->new(code => 'invalid_request', message => 'Expected sql string and bind array')
    unless ref $m eq 'HASH' && defined $m->{sql} && !ref $m->{sql} && length $m->{sql}
      && length($m->{sql}) <= 50000 && ref $m->{bind} eq 'ARRAY' && @{$m->{bind}} <= 1000;
  for (@{$m->{bind}}) {
    die PgTunnel::Error->new(code => 'invalid_bind', message => 'Bind values must be scalars or null') if ref;
  }
  PgTunnel::SQL::validate($m->{sql});
}
sub _pack ($self, $results) {
  my $columns = $results->columns // [];
  my @data;
  if (@$columns) {
    while (my $row = $results->array) {
      die PgTunnel::Error->new(code => 'result_limit', message => 'Too many rows; add LIMIT or paginate')
        if @data >= $self->max_rows;
      push @data, [@$row];
    }
  }
  my $body = {ok => true, result => {columns => $columns, data => \@data,
    affected_rows => 0 + $results->rows}};
  die PgTunnel::Error->new(code => 'result_limit', message => 'Result exceeds byte limit')
    if length(encode_json($body)) > $self->max_bytes;
  return $body;
}
sub _take ($self) {
  die PgTunnel::Error->new(code => 'busy', message => 'Gateway connection limit reached')
    if $self->_active >= $self->max_active;
  $self->_active($self->_active + 1);
}
sub _http ($self, $c) {
  my $m = $c->req->json;
  eval { $self->_validate($m) };
  return $c->render(status => 400, json => $self->_failure($@)) if $@;
  eval { $self->_take };
  return $c->render(status => 503, json => $self->_failure($@)) if $@;
  $c->render_later;
  my ($db, $gone, $body);
  $c->on(finish => sub { $gone = 1 });
  Mojo::Promise->resolve->then(sub {
    $db = $self->pg->db;
    return $db->query_p('BEGIN');
  })->then(sub {
    return $db->query_p($m->{sql}, @{$m->{bind}});
  })->then(sub ($r) {
    $body = $self->_pack($r);
    die 'Client disconnected before commit' if $gone;
    return $db->query_p('COMMIT');
  })->then(sub {
    $c->render(json => $body) unless $gone;
  })->catch(sub ($err) {
    $c->render(status => 400, json => $self->_failure($err, $db)) unless $gone;
  })->finally(sub {
    # Never return user-controlled session state or an open transaction to a pool.
    eval { $db->disconnect } if $db;
    $self->_active($self->_active - 1);
  });
}
sub _ws ($self, $c) {
  eval { $self->_take };
  return $c->render(status => 503, json => $self->_failure($@)) if $@;
  my ($db, $busy, $ready, $gone, $released, $failed, $started) = (undef, 0, 0, 0, 0, 0, 0);
  $c->inactivity_timeout(int($self->idle_ms / 1000) + 10);
  $c->tx->max_websocket_size(65536);
  my $release = sub {
    return if $released || $busy;
    $released = 1;
    # Closing libpq rolls back an uncommitted transaction. Wait for an in-flight
    # query callback first; never disconnect a handle while Mojo::Pg watches it.
    eval { $db->disconnect } if $db;
    $db = undef;
    $self->_active($self->_active - 1);
  };
  $c->on(finish => sub { $gone = 1; $release->() });
  my $start = sub {
    $started = 1; $busy = 1;
    Mojo::Promise->resolve->then(sub {
      $db = $self->pg->db;
      return $db->query_p('BEGIN');
    })->then(sub {
      $ready = 1; $busy = 0;
      if ($gone) { $release->(); return }
      $c->send({json => {ok => true, ready => true}});
    })->catch(sub ($err) {
      $busy = 0;
      unless ($gone) { $c->send({json => $self->_failure($err, $db)}); $c->finish(1011) }
      $release->();
    });
  };
  $c->on(message => sub ($c, $text) {
    my $m = eval { decode_json($text) };
    if (ref $m eq 'HASH' && ($m->{op} // '') eq 'start' && !$started) {
      $start->(); return;
    }
    unless (ref $m eq 'HASH' && defined $m->{id} && !ref $m->{id}
        && $m->{id} =~ /^[1-9][0-9]{0,14}$/ && defined $m->{op} && !ref $m->{op}
        && $m->{op} =~ /^(query|commit|rollback)$/) {
      $c->send({json => _err('invalid_request', 'Invalid transaction message')});
      $c->finish(1008); return;
    }
    my $reply = sub ($body) { $c->send({json => {%$body, id => $m->{id}}}) unless $gone };
    if (!$ready || $busy) { $reply->(_err('busy', 'Await the previous operation')); return }
    if ($failed && $m->{op} ne 'rollback') {
      $reply->(_err('transaction_failed', 'Transaction must be rolled back')); return;
    }
    if ($m->{op} eq 'query') {
      eval { $self->_validate($m) };
      if ($@) { $reply->($self->_failure($@)); return }
    }
    $busy = 1;
    my $sql = $m->{op} eq 'query' ? $m->{sql} : uc $m->{op};
    my @bind = $m->{op} eq 'query' ? @{$m->{bind}} : ();
    Mojo::Promise->resolve->then(sub { $db->query_p($sql, @bind) })->then(sub ($r) {
      if ($m->{op} eq 'query') {
        # DBD::Pg ping=3 means idle inside a transaction.
        die PgTunnel::Error->new(code => 'transaction_ended', message => 'SQL ended the managed transaction')
          unless $db->dbh->ping == 3;
        $reply->($self->_pack($r));
      } else {
        $reply->({ok => true});
        $gone = 1; $c->finish(1000);
      }
    })->catch(sub ($err) {
      $failed = 1;
      $reply->($self->_failure($err, $db));
    })->finally(sub {
      $busy = 0; $release->() if $gone;
    });
  });
}
1;
