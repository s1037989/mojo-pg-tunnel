package PgTunnel::Error;
use Mojo::Base -base, -signatures;
use overload '""' => sub { $_[0]->message }, fallback => 1;
has code => 'remote_error';
has message => 'Remote database error';
has [qw(sqlstate status)];
1;
