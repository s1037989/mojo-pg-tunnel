requires 'perl', '5.020';
requires 'Mojolicious', '9.31';
requires 'Mojo::Pg', '4.27'; # gateway only; includes DBI and DBD::Pg
requires 'IO::Socket::SSL', '2.009';
on test => sub { requires 'Test::More'; };
