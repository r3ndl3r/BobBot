package Command::ATs;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use Mojo::JSON qw(decode_json);
use namespace::clean;
use Time::ParseDate;
use POSIX qw(floor);

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_ats);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has name                => ( is => 'ro', default => 'ATs' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'ATs' );
has pattern             => ( is => 'ro', default => '^ats ?' );
has function            => ( is => 'ro', default => sub { \&cmd_ats } );
has usage               => ( is => 'ro', default => <<EOF
Usage:
    !ats all
    !ats overdue
    !ats next
EOF
);

sub cmd_ats
{
    my %units = (
        'VU21989' => 'David',
        'VU21997' => 'Ajay',
        'VU21995' => 'Raja / Kate',
        'VU21991' => 'Le',
        'VU21996' => 'Martin'
    );

    my @ats = (
        'VU21989 AT1 2/Mar/2022 23:59:00',
        'VU21989 AT2 3/Apr/2022 23:59:00',
        'VU21997 AT1 20/Mar/2022 23:59:00',
        'VU21997 AT2 27/Mar/2022 23:59:00',
        'VU21997 AT3 10/Apr/2022 23:59:00',
        'VU21995 AT1 11/Mar/2022 23:59:00',
        'VU21995 AT2-5 1/May/2022 23:59:00',
        'VU21995 AT6-8 19/June/2022 8:59:00',
        'VU21991 AT1 3/Apr/2022 23:59:00',
        'VU21991 AT2 17/Apr/2022 23:59:00',
        'VU21991 AT3 12/Jun/2022 23:00:00',
        'VU21996 AT1 13/Mar/2022 23:59:00',
        'VU21996 AT2 10/Apr/2022 23:59:00',
    );

    my %ats;
    for (sort @ats) {
        my ($unit, $at, $date) = /^(\S+) (\S+) (.*)/;
        my $secs = parsedate($date);
        $ats{"$unit-$at"} = $secs;  
    }

    my ($self, $msg) = @_;

    my $channel = $msg->{'channel_id'};
    my $author = $msg->{'author'};
    my $args = $msg->{'content'};

    my $pattern = $self->pattern;
    $args =~ s/$pattern//i;

    my $discord = $self->discord;
    my $replyto = '<@' . $author->{'id'} . '>';

    if ($args eq 'next') {

        for (sort { $ats{$a} <=> $ats{$b} } keys %ats) {

         if ($ats{$_} - time() > 0) {
                 my ($unit, $at) = split /-/, $_;
                $discord->send_message($channel, "The next AT due: $at for $unit ($units{$unit}) is due in " . howOld($ats{$_}));
                $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
                return;
            } 
        }

    } elsif ($args eq 'all') {

        my @msg;

        for (sort { $ats{$a} <=> $ats{$b} } keys %ats) {
            my ($unit, $at) = ($_ =~ /^([^-]+)-(.*)/);

            if ($ats{$_} - time() > 0) {
                push @msg, "$at for $unit ($units{$unit}) is due in " . howOld( $ats{$_}, 0 );
            }
        }

        $discord->send_message($channel, join "\n", @msg);
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");

    } elsif ($args eq 'overdue') {

        my @msg;
        for (sort { $ats{$a} <=> $ats{$b} } keys %ats) {
            my ($unit, $at) = ($_ =~ /^([^-]+)-(.*)/);

            if ($ats{$_} - time() < 0) {
                $ats{$_} =~ s/-//;
                push @msg, "$at for $unit ($units{$unit}) is overdue by " . howOld( $ats{$_}, 1 );
            }
        }

        $discord->send_message($channel, join "\n", @msg);
        $discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");

    }  elsif ($args eq 'fuck') {
        $discord->send_message($channel, "$replyto: fuck you");
    }
 }

sub howOld {
    my ($dob, $over) = @_;
    my $diff = !$over ? $dob - time : time - $dob;

    return sprintf "%d day(s)", floor($diff / 86400);

}

1;
