package Hailo::Storage::SQL;
use 5.10.0;
use Moose;
use MooseX::Method::Signatures;
use MooseX::StrictConstructor;
use MooseX::Types::Moose qw<ArrayRef HashRef Int Str Bool>;
use DBI;
use List::Util qw<shuffle>;
use Data::Section qw(-setup);
use Template;
use namespace::clean -except => [ qw(meta
                                     section_data
                                     section_data_names
                                     merged_section_data
                                     merged_section_data_names) ];

our $VERSION = '0.01';

has dbh => (
    isa        => 'DBI::db',
    is         => 'ro',
    lazy_build => 1,
);

has dbd => (
    isa           => Str,
    is            => 'ro',
    documentation => "The DBD::* driver we're using",
);

method _build_dbh {
    my $dbd_options = $self->dbi_options;

    return DBI->connect($self->dbi_options);
};

has dbi_options => (
    isa => ArrayRef,
    is => 'ro',
    auto_deref => 1,
    lazy_build => 1,
);

method _build_dbi_options {
    my $dbd = $self->dbd;
    my $dbd_options = $self->dbd_options;
    my $db = $self->brain // '';

    my @options = (
        "dbi:$dbd:dbname=$db",
        '',
        '',
        $dbd_options,
    );

    return \@options;
}

has dbd_options => (
    isa        => HashRef,
    is         => 'ro',
    lazy_build => 1,
);

method _build_dbd_options {
    return {
        RaiseError => 1
    };
}

has _engaged => (
    isa           => Bool,
    is            => 'rw',
    default       => 0,
    documentation => "Have we done setup work to get this database going?",
);

has sth => (
    isa        => HashRef,
    is         => 'ro',
    lazy_build => 1,
);

# our statement handlers
method _build_sth {
    my $sections = $self->_sth_sections();
    my %state;
    while (my ($name, $options) = each %$sections) {
        my $section = $options->{section} // $name;
        my %options = %{ $options->{options} // {} };
        my $template = $self->section_data("query_$section");
        my $sql;
        Template->new->process(
            $template,
            {
                orders => [ 0 .. $self->order-1 ],
                %options,
            },
            \$sql,
        );
        $state{$name} = $sql;
    }

    $state{$_} = $self->dbh->prepare($state{$_}) for keys %state;
    return \%state;
}

method _sth_sections {
    my %sections;

    # () sections are magical
    my @plain_sections = grep { /^query_/ and not /\(.*?\)/ } $self->section_data_names;
    s[^query_][] for @plain_sections;

    $sections{$_} = undef for @plain_sections;

    for my $np (qw(next_token prev_token)) {
        for my $ciag (qw(count inc add get)) {
            $sections{$np . '_' . $ciag} = {
                section => "(next_token|prev_token)_$ciag",
                options => { table => $np },
            };
        }
    }

    for my $order (0 .. $self->order-1) {
        $sections{"expr_id_token${order}_id"} = {
            section => 'expr_id_token(NUM)_id',
            options => { column => "token${order}_id" },
        };
    }

    {
        my @columns = map { "token${_}_id" } 0 .. $self->order-1;
        my @ids = join(', ', ('?') x @columns);
        $sections{add_expr} = {
            section => '(add_expr)',
            options => {
                columns => join(', ', @columns),
                ids     => join(', ', @ids),
            }
        }
    }

    return \%sections;
}

method _engage {
    if ($self->_exists_db) {
        $self->sth->{get_order}->execute();
        my $order = $self->sth->{get_order}->fetchrow_array();
        $self->order($order);

        $self->sth->{get_separator}->execute();
        my $sep = $self->sth->{get_separator}->fetchrow_array();
        $self->token_separator($sep);
    }
    else {
        $self->_create_db();

        my $order = $self->order;
        $self->sth->{set_order}->execute($order);

        my $sep = $self->token_separator;
        $self->sth->{set_separator}->execute($sep);
    }

    return;
}

method start_training {
    $self->start_learning();
    return;
}

method stop_training {
    $self->stop_learning();
    return;
}

method start_learning {
    if (not $self->_engaged()) {
        # Engage!
        $self->_engage();
        $self->_engaged(1);
    }

    # start a transaction
    $self->dbh->begin_work;
    return;
}

method stop_learning {
    # finish a transaction
    $self->dbh->commit;
    return;
}

method _create_db {
    my @statements = $self->_get_create_db_sql;

    $self->dbh->do($_) for @statements;

    return;
}

method _get_create_db_sql {
    my $sql;

    for my $section (qw(info token expr next_token prev_token indexes)) {
        my $template = $self->section_data("table_$section");
        Template->new->process(
            $template,
            {
                orders => [ 0 .. $self->order-1 ],
            },
            \$sql,
        );
    }

    return ($sql =~ /\s*(.*?);/gs);
}

method _expr_text(ArrayRef $tokens) {
    return join $self->token_separator, @$tokens;
}

# add a new expression to the database
method add_expr(HashRef $args) {
    my $tokens    = $args->{tokens};
    my $expr_text = $self->_expr_text($tokens);
    my $expr_id   = $self->_expr_id($expr_text);

    if (!defined $expr_id) {
        # add the tokens
        my @token_ids = $self->_add_tokens($tokens);

        $expr_id = $self->_add_expr(\@token_ids, $args->{can_start}, $args->{can_end}, $expr_text);
    }

    # add next/previous tokens for this expression, if any
    for my $pos_token (qw(next_token prev_token)) {
        next if !defined $args->{$pos_token};
        my $token_id = $self->_add_tokens([$args->{$pos_token}]);

        my $get_count = "${pos_token}_count";
        $self->sth->{$get_count}->execute($expr_id, $token_id);
        my $count = $self->sth->{$get_count}->fetchrow_array;

        if (defined $count) {
            my $new_count = $count++;
            my $inc_count = "${pos_token}_inc";
            $self->sth->{$inc_count}->execute($new_count, $expr_id, $token_id);
        }
        else {
            my $add_count = "${pos_token}_add";
            $self->sth->{$add_count}->execute($expr_id, $token_id);
        }
    }

    return;
}

method _add_expr(ArrayRef $token_ids, Bool $can_start, Bool $can_end, Str $expr_text) {
    # add the expression
    $self->sth->{add_expr}->execute(@$token_ids, $can_start, $can_end, $expr_text);

    # get the new expr id
    $self->sth->{last_expr_rowid}->execute();
    return $self->sth->{last_expr_rowid}->fetchrow_array;
}

# look up an expression id based on tokens
method _expr_id(Str $expr_text) {
    $self->sth->{expr_id}->execute($expr_text);
    return scalar $self->sth->{expr_id}->fetchrow_array();
}

method expr_can(ArrayRef $tokens) {
    my $expr_text = $self->_expr_text($tokens);
    $self->sth->{expr_can}->execute($expr_text);
    return $self->sth->{expr_can}->fetchrow_array();
}

# add tokens and/or return their ids
method _add_tokens(ArrayRef $tokens) {
    my @token_ids;

    for my $token (@$tokens) {
        $self->sth->{token_id}->execute($token);
        my $old_token_id = $self->sth->{token_id}->fetchrow_array();

        if (defined $old_token_id) {
            push @token_ids, $old_token_id;
        }
        else {
            push @token_ids, => $self->_add_token($token);
        }
    }

    return @token_ids > 1 ? @token_ids : $token_ids[0];
}

method _add_token(Str $token) {
    $self->sth->{add_token}->execute($token);
    $self->sth->{last_token_rowid}->execute();
    return $self->sth->{last_token_rowid}->fetchrow_array;
}

method token_exists(Str $token) {
    $self->sth->{token_id}->execute($token);
    return defined $self->sth->{token_id}->fetchrow_array();
}

method _split_expr($self:Str $expr) {
    my $sep = quotemeta $self->token_separator;
    return split /$sep/, $expr;
}

# return a random expression containing the given token
method random_expr(Str $token) {
    my $dbh = $self->dbh;

    my $token_id = $self->_add_tokens([$token]);
    my @expr;

    # try the positions in a random order
    for my $pos (shuffle 0 .. $self->order-1) {
        my $column = "token${pos}_id";

        # find all expressions which include the token at this position
        $self->sth->{"expr_id_$column"}->execute($token_id);
        my $expr_ids = $self->sth->{"expr_id_$column"}->fetchall_arrayref();
        $expr_ids = [ map { $_->[0] } @$expr_ids ];

        # try the next position if no expression has it at this one
        next if !@$expr_ids;

        # we found some, let's pick a random one and return it
        my $expr_id = $expr_ids->[rand @$expr_ids];
        $self->sth->{expr_by_id}->execute($expr_id);
        my ($can_start, $can_end, $expr_text) = $self->sth->{expr_by_id}->fetchrow_array();
        @expr = ($can_start, $can_end, $self->_split_expr($expr_text));

        last;
    }
    return @expr;
}

method next_tokens(ArrayRef $tokens) {
    return $self->_pos_tokens('next_token', $tokens);
}

method prev_tokens(ArrayRef $tokens) {
    return $self->_pos_tokens('prev_token', $tokens);
}

method _pos_tokens(Str $pos_table, ArrayRef $tokens) {
    my $dbh = $self->dbh;

    my $expr_text = $self->_expr_text($tokens);
    my $expr_id = $self->_expr_id($expr_text);

    $self->sth->{"${pos_table}_get"}->execute($expr_id);
    my $ugly_hash = $self->sth->{"${pos_table}_get"}->fetchall_hashref('text');
    my %clean_hash = map { +$_ => $ugly_hash->{$_}{count} } keys %$ugly_hash;
    return \%clean_hash;
}

method save {
    # no op
}

with qw(Hailo::Role::Generic
        Hailo::Role::Storage);

__PACKAGE__->meta->make_immutable;

=encoding utf8

=head1 NAME

Hailo::Storage::SQL - A skeleton SQL backend meant to be subclassed

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

E<AElig>var ArnfjE<ouml>rE<eth> Bjarmason <avar@cpan.org>

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Hinrik E<Ouml>rn SigurE<eth>sson and E<AElig>var ArnfjE<ouml>rE<eth> Bjarmason

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__DATA__
__[ table_info ]__
CREATE TABLE info (
    attribute TEXT NOT NULL UNIQUE PRIMARY KEY,
    text      TEXT NOT NULL
);
__[ table_token ]__
CREATE TABLE token (
    token_id INTEGER PRIMARY KEY AUTOINCREMENT,
    text     TEXT NOT NULL
);
__[ table_expr ]__
CREATE TABLE expr (
    expr_id   INTEGER PRIMARY KEY AUTOINCREMENT,
    can_start BOOL,
    can_end   BOOL,
[% FOREACH i IN orders %]
    token[% i %]_id INTEGER NOT NULL REFERENCES token (token_id),
[% END %]
    expr_text TEXT NOT NULL UNIQUE
);
__[ table_next_token ]__
CREATE TABLE next_token (
    pos_token_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    expr_id      INTEGER NOT NULL REFERENCES expr (expr_id),
    token_id     INTEGER NOT NULL REFERENCES token (token_id),
    count        INTEGER NOT NULL
);
__[ table_prev_token ]__
CREATE TABLE prev_token (
    pos_token_id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    expr_id      INTEGER NOT NULL REFERENCES expr (expr_id),
    token_id     INTEGER NOT NULL REFERENCES token (token_id),
    count        INTEGER NOT NULL
);
__[ table_indexes ]__
CREATE INDEX token_text ON token (text);
[% FOREACH i IN orders %]
CREATE INDEX expr_token[% i %]_id on expr (token[% i %]_id);
[% END %]
CREATE INDEX next_token_expr_id ON next_token (expr_id);
CREATE INDEX prev_token_expr_id ON prev_token (expr_id);
__[ query_get_order ]__
SELECT text FROM info WHERE attribute = 'markov_order';
__[ query_get_separator ]__
SELECT text FROM info WHERE attribute = 'token_separator';
__[ query_set_order ]__
INSERT INTO info (attribute, text) VALUES ('markov_order', ?);
__[ query_set_separator ]__
INSERT INTO info (attribute, text) VALUES ('token_separator', ?);
__[ query_expr_id ]__
SELECT expr_id FROM expr WHERE expr_text = ?;
__[ query_expr_id_token(NUM)_id ]__
SELECT expr_id FROM expr WHERE [% column %] = ?;
__[ query_expr_by_id ]__
SELECT can_start, can_end, expr_text FROM expr WHERE expr_id = ?;
__[ query_expr_can ]__
SELECT can_start, can_end FROM expr WHERE expr_text = ?;
__[ query_token_id ]__
SELECT token_id FROM token WHERE text = ?;
__[ query_add_token ]__
INSERT INTO token (text) VALUES (?);
__[ query_last_expr_rowid ]_
SELECT expr_id  FROM expr  ORDER BY expr_id  DESC LIMIT 1;
__[ query_last_token_rowid ]__
SELECT token_id FROM token ORDER BY token_id DESC LIMIT 1;
__[ query_(next_token|prev_token)_count ]__
SELECT count FROM [% table %] WHERE expr_id = ? AND token_id = ?;
__[ query_(next_token|prev_token)_inc ]__
UPDATE [% table %] SET count = ? WHERE expr_id = ? AND token_id = ?
__[ query_(next_token|prev_token)_add ]__
INSERT INTO [% table %] (expr_id, token_id, count) VALUES (?, ?, 1);
__[ query_(next_token|prev_token)_get ]__
SELECT t.text, p.count
  FROM token t
INNER JOIN [% table %] p
        ON p.token_id = t.token_id
     WHERE p.expr_id = ?;
__[ query_(add_expr) ]__
INSERT INTO expr ([% columns %], can_start, can_end, expr_text) VALUES ([% ids %], ?, ?, ?);
