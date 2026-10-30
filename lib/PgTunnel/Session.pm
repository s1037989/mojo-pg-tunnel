package PgTunnel::Session;
use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json);
use Mojo::Promise;
use Scalar::Util qw(weaken);
has [qw(client tx _pending _timer)];
has _seq => 0;
has _closed => 0;

sub ready_p ($self) {
  my $p = Mojo::Promise->new;
  $self->_pending({promise => $p, ready => 1});
  my $weak = $self; weaken $weak;
  $self->tx->on(message => sub ($tx, $text) {
    return unless $weak;
    my $body = eval { decode_json($text) };
    return $weak->_fail('Invalid gateway WebSocket response') unless ref $body eq 'HASH';
    my $pending = $weak->_pending // return;
    if ($pending->{ready}) {
      return $weak->_fail($weak->client->_error($body)) unless $body->{ok};
      return $weak->_fail('Gateway could not begin transaction') unless $body->{ready} && $body->{ok};
      $weak->_clear;
      return $pending->{promise}->resolve($weak);
    }
    return $weak->_fail('Mismatched gateway response id') unless
      defined $body->{id} && $body->{id} eq $pending->{id};
    $weak->_clear;
    return $pending->{promise}->reject($weak->client->_error($body)) unless $body->{ok};
    if ($pending->{op} eq 'query') {
      my $r = eval { $weak->client->_result($body) };
      return $pending->{promise}->reject($@) if $@;
      return $pending->{promise}->resolve($r);
    }
    $weak->_closed(1);
    $tx->finish(1000);
    $pending->{promise}->resolve(1);
  });
  $self->tx->on(finish => sub { $weak->_fail('Connection lost; transaction outcome may be unknown') if $weak });
  $self->_arm;
  # Ask for BEGIN after listeners are installed; an unsolicited ready message
  # could otherwise arrive in the HTTP upgrade packet before websocket_p runs.
  $self->tx->send({json => {op => 'start'}});
  return $p->then(sub { return $self });
}
sub _clear ($self) {
  Mojo::IOLoop->remove($self->_timer) if defined $self->_timer;
  $self->_timer(undef); $self->_pending(undef);
}
sub _arm ($self) {
  my $weak = $self; weaken $weak;
  $self->_timer(Mojo::IOLoop->timer($self->client->timeout => sub {
    $weak->_fail('Gateway timeout; transaction outcome may be unknown') if $weak;
  }));
}
sub _fail ($self, $message) {
  my $pending = $self->_pending;
  my $was_closed = $self->_closed;
  $self->_clear; $self->_closed(1);
  $self->tx->finish(1000) unless $was_closed || $self->tx->is_finished;
  my $err = ref $message ? $message : PgTunnel::Error->new(code => 'connection_lost', message => $message);
  $pending->{promise}->reject($err) if $pending;
}
sub _request_p ($self, $op, %args) {
  return Mojo::Promise->reject('Transaction is closed') if $self->_closed;
  return Mojo::Promise->reject('Await the previous transaction operation first') if $self->_pending;
  my $id = $self->_seq + 1; $self->_seq($id);
  my $p = Mojo::Promise->new;
  $self->_pending({promise => $p, id => $id, op => $op});
  $self->_arm;
  $self->tx->send({json => {id => $id, op => $op, %args}});
  return $p;
}
sub query_p ($self, $sql, @bind) { $self->_request_p(query => sql => $sql, bind => \@bind) }
sub commit_p ($self) { $self->_request_p('commit') }
sub rollback_p ($self) { $self->_request_p('rollback') }
sub close ($self) { $self->_fail('Transaction closed by client') }
sub DESTROY ($self) {
  Mojo::IOLoop->remove($self->_timer) if defined $self->_timer;
  $self->tx->finish(1000) if $self->tx && !$self->_closed && !$self->tx->is_finished;
}
1;
