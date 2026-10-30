package PgTunnel::SQL;
use Mojo::Base -strict, -signatures;
use PgTunnel::Error;

# A deliberately conservative lexer, not an SQL authorization policy.
# Support one statement, standard-conforming strings, E strings, dollar quotes,
# quoted identifiers, line comments and nested PostgreSQL block comments.
sub validate ($sql) {
  my ($i, $n, $ended, $first) = (0, length($sql), 0, undef);
  while ($i < $n) {
    my $rest = substr($sql, $i);
    if ($rest =~ /\A\s+/) { $i += length $&; next }
    if ($rest =~ /\A--[^\n]*(?:\n|\z)/) { $i += length $&; next }
    if (substr($rest, 0, 2) eq '/*') {
      $i += 2; my $depth = 1;
      while ($i < $n && $depth) {
        my $pair = substr($sql, $i, 2);
        if ($pair eq '/*') { ++$depth; $i += 2 }
        elsif ($pair eq '*/') { --$depth; $i += 2 }
        else { ++$i }
      }
      _invalid() if $depth;
      next;
    }
    _invalid() if $ended;
    if ($rest =~ /\A([A-Za-z_][A-Za-z_0-9\$]*)/) {
      my $word = $1;
      if ($word =~ /^[Ee]$/ && substr($rest, 1, 1) eq "'") {
        $i = _quote($sql, $i + 1, "'", 1); next;
      }
      $first //= uc $word; $i += length $word; next;
    }
    my $ch = substr($sql, $i, 1);
    if ($ch eq "'" || $ch eq '"') { $i = _quote($sql, $i, $ch, 0); next }
    if ($rest =~ /\A(\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$)/) {
      my $tag = $1; my $end = index($sql, $tag, $i + length $tag);
      _invalid() if $end < 0;
      $i = $end + length $tag; next;
    }
    if ($ch eq ';') { $ended = 1 }
    ++$i;
  }
  die PgTunnel::Error->new(code => 'unsupported_sql', message => 'Unsupported SQL command; use transaction methods for commit/rollback')
    unless defined $first && $first =~ /^(SELECT|INSERT|UPDATE|DELETE|WITH|VALUES|SHOW|EXPLAIN|CREATE|ALTER|DROP|TRUNCATE|COMMENT|GRANT|REVOKE|ANALYZE)$/;
  return 1;
}
sub _quote ($sql, $i, $quote, $escapes) {
  my $n = length $sql; ++$i;
  while ($i < $n) {
    my $ch = substr($sql, $i++, 1);
    if ($escapes && $ch eq '\\') { ++$i; next }
    if ($ch eq $quote) {
      if (substr($sql, $i, 1) eq $quote) { ++$i; next }
      return $i;
    }
  }
  _invalid();
}
sub _invalid { die PgTunnel::Error->new(code => 'invalid_sql', message => 'Use one well-formed SQL statement per call') }
1;
