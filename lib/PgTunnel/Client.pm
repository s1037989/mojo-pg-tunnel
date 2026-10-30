package PgTunnel::Client;
use Mojo::Base -base, -signatures;
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::Promise;
use PgTunnel::Session;
use PgTunnel::Error;
use PgTunnel::Results;
has url => 'http://127.0.0.1:3001';
has token => '';
has timeout => 40;
has idle_timeout => 75;
has allow_insecure => 0;
has ua => sub { Mojo::UserAgent->new->max_redirects(0)->max_response_size(2 * 1024 * 1024) };

sub _url ($self, $path, $websocket = 0) {
  my $url = Mojo::URL->new($self->url);
  die 'Gateway URL must be an http(s) origin with no credentials, query, or path' if
    ($url->scheme // '') !~ /^https?$/ || !$url->host || $url->userinfo ||
    $url->query->to_string || $url->fragment || $url->path->to_string !~ m{^/?$};
  die 'Use HTTPS, or explicitly allow insecure development transport' if
    $url->scheme eq 'http' && !$self->allow_insecure;
  die 'A bearer token is required' unless length $self->token;
  $url->path($path);
  $url->scheme($url->scheme eq 'https' ? 'wss' : 'ws') if $websocket;
  return $url;
}
sub _headers ($self) { return {Authorization => 'Bearer ' . $self->token} }
sub _error ($self, $body, $status = undef) {
  my $e = ref $body eq 'HASH' && ref $body->{error} eq 'HASH' ? $body->{error} : {};
  return PgTunnel::Error->new(code => $e->{code} // 'protocol_error',
    message => $e->{message} // 'Gateway returned an invalid response',
    sqlstate => $e->{sqlstate}, status => $status);
}
sub _result ($self, $body) {
  die $self->_error($body) unless ref $body eq 'HASH' && $body->{ok};
  my $r = $body->{result};
  die 'Invalid gateway result' unless ref $r eq 'HASH' && ref $r->{columns} eq 'ARRAY'
    && ref $r->{data} eq 'ARRAY';
  return PgTunnel::Results->new(%$r);
}
sub query_p ($self, $sql, @bind) {
  return Mojo::Promise->resolve->then(sub {
    $self->ua->request_timeout($self->timeout);
    return $self->ua->post_p($self->_url('/v1/query') => $self->_headers =>
      json => {sql => $sql, bind => \@bind});
  })->then(sub ($tx) {
    my $res = $tx->result;
    die $self->_error($res->json, $res->code) unless $res->is_success;
    return $self->_result($res->json);
  });
}
sub begin_p ($self) {
  return Mojo::Promise->resolve->then(sub {
    $self->ua->request_timeout($self->timeout);
    $self->ua->inactivity_timeout($self->idle_timeout);
    return $self->ua->websocket_p($self->_url('/v1/transaction', 1) => $self->_headers);
  })->then(sub ($tx) {
    $tx->max_websocket_size(2 * 1024 * 1024);
    return PgTunnel::Session->new(client => $self, tx => $tx)->ready_p;
  });
}
sub transaction_p ($self, $code) {
  return $self->begin_p->then(sub ($session) {
    return Mojo::Promise->resolve->then(sub { $code->($session) })->then(sub (@values) {
      return $session->commit_p->then(sub { return @values });
    })->catch(sub ($err) {
      # A lost COMMIT reply is indeterminate. Never retry the transaction.
      return $session->rollback_p->catch(sub { return undef })->then(sub { die $err });
    });
  });
}
1;
