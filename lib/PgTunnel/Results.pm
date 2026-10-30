package PgTunnel::Results;
use Mojo::Base -base, -signatures;
use Mojo::Collection;
has columns => sub { [] };
has data => sub { [] };
has affected_rows => 0;
has _index => 0;
sub rows ($self) { $self->affected_rows }
sub array ($self) {
  return undef if $self->_index >= @{$self->data};
  my $row = $self->data->[$self->_index];
  $self->_index($self->_index + 1);
  return $row;
}
sub hash ($self) {
  my $row = $self->array // return undef;
  my %hash; @hash{@{$self->columns}} = @$row;
  return \%hash;
}
sub arrays ($self) {
  my @rows; while (my $r = $self->array) { push @rows, $r }
  return Mojo::Collection->new(@rows);
}
sub hashes ($self) {
  my @rows; while (my $r = $self->hash) { push @rows, $r }
  return Mojo::Collection->new(@rows);
}
1;
