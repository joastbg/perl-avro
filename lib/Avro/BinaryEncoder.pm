package Avro::BinaryEncoder;
use strict;
use warnings;

use Encode();
use Error::Simple;
use Config;

our $complement = ~0x7F;
unless ($Config{use64bitint}) {
    require Math::BigInt;
    $complement = Math::BigInt->new("0b" . ("1" x 57) . ("0" x 7));
}

sub encode {
    my $class = shift;
    my ($schema, $data, $cb) = @_;

    ## a schema can also be just a string
    my $type = ref $schema ? $schema->type : $schema;

    ## might want to profile and optimize this
    my $meth = "encode_$type";
    $class->$meth($schema, $data, $cb);
    return;
}

sub encode_null {
    $_[3]->(\'');
}

sub encode_boolean {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    $cb->( $data ? \0x1 : \0x0 );
}

sub encode_int {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    my @count = unpack "W*", $data;
    if (scalar @count > 4) {
        throw Avro::BinaryEncoder::Error("int should be 32bits");
    }

    my $enc = unsigned_varint(zigzag($data));
    $cb->(\$enc);
}

sub encode_long {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    my @count = unpack "W*", $data;
    if (scalar @count > 8) {
        throw Avro::BinaryEncoder::Error("int should be 64bits");
    }
    my $enc = unsigned_varint(zigzag($data));
    $cb->(\$enc);
}

sub encode_float {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    my $enc = pack "f<", $data;
    $cb->(\$enc);
}

sub encode_double {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    my $enc = pack "d<", $data;
    $cb->(\$enc);
}

sub encode_bytes {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    encode_long($class, undef, bytes::length($data), $cb);
    $cb->(\$data);
}

sub encode_string {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    my $bytes = Encode::encode_utf8($data);
    encode_long($class, undef, bytes::length($bytes), $cb);
    $cb->(\$bytes);
}

## 1.3.2 A record is encoded by encoding the values of its fields in the order
## that they are declared. In other words, a record is encoded as just the
## concatenation of the encodings of its fields. Field values are encoded per
## their schema.
sub encode_record {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    for my $field (@{ $schema->fields }) {
        $class->encode($field->{type}, $data->{ $field->{name} }, $cb);
    }
}

## 1.3.2 An enum is encoded by a int, representing the zero-based position of
## the symbol in the schema.
sub encode_enum {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    my $symbols = $schema->symbols;
    my $pos = $symbols->{ $data };
    throw Avro::BinaryEncoder::Error("Cannot find enum $data")
        unless $pos;
    $pos--;
    $class->encode_int(undef, $pos, $cb);
}

## 1.3.2 Arrays are encoded as a series of blocks. Each block consists of a
## long count value, followed by that many array items. A block with count zero
## indicates the end of the array. Each item is encoded per the array's item
## schema.
## If a block's count is negative, its absolute value is used, and the count is
## followed immediately by a long block size

## maybe here it would be worth configuring what a typical block size should be
sub encode_array {
    my $class = shift;
    my ($schema, $data, $cb) = @_;

    ## FIXME: multiple blocks
    if (@$data) {
        $class->encode_long(undef, scalar @$data, $cb);
        for (@$data) {
            $class->encode($schema->items, $_, $cb);
        }
    }
    ## end of the only block
    $class->encode_long(undef, 0, $cb);
}


## 1.3.2 Maps are encoded as a series of blocks. Each block consists of a long
## count value, followed by that many key/value pairs. A block with count zero
## indicates the end of the map. Each item is encoded per the map's value
## schema.
##
## (TODO)
## If a block's count is negative, its absolute value is used, and the count is
## followed immediately by a long block size indicating the number of bytes in
## the block. This block size permits fast skipping through data, e.g., when
## projecting a record to a subset of its fields.
sub encode_map {
    my $class = shift;
    my ($schema, $data, $cb) = @_;

    my @keys = keys %$data;
    if (@keys) {
        $class->encode_long(undef, scalar @keys, $cb);
        for (@keys) {
            ## the key
            $class->encode_string(undef, $_, $cb);

            ## the value
            $class->encode($schema->values->{$_}, $data->{$_}, $cb);
        }
    }
    ## end of the only block
    $class->encode_long(undef, 0, $cb);
}

## 1.3.2 A union is encoded by first writing a long value indicating the
## zero-based position within the union of the schema of its value. The value
## is then encoded per the indicated schema within the union.
sub encode_union {
    my $class = shift;
    my ($schema, $data, $cb) = @_;

}

## 1.3.2 Fixed instances are encoded using the number of bytes declared in the
## schema.
sub encode_fixed {
    my $class = shift;
    my ($schema, $data, $cb) = @_;
    if (bytes::length $data != $schema->size) {
        my $s1 = bytes::length $data;
        my $s2 = $schema->size;
        throw Avro::BinaryEncoder::Error("Fixed size doesn't match $s1!=$s2");
    }
    $class->encode_bytes(undef, $data, $cb);
}

sub zigzag {
    use warnings FATAL => 'numeric';
    if ( $_[0] >= 0 ) {
        return $_[0] << 1;
    }
    return (($_[0] << 1) ^ -1) | 0x1;
}

sub unsigned_varint {
    my @bytes;
    while ($_[0] & $complement ) {          # mask with continuation bit
        push @bytes, ($_[0] & 0x7F) | 0x80; # out and set continuation bit
        $_[0] >>= 7;                        # next please
    }
    push @bytes, $_[0]; # last byte
    return pack "W*", @bytes; ## TODO C
}

package Avro::BinaryEncoder::Error;
use parent 'Error::Simple';

1;
