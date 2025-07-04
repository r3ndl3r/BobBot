package Command::Forecast;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use XML::Simple;
use Date::Parse;
use Component::DBI;
use Data::Dumper;
use POSIX qw(strftime);

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_forecast);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );

has name                => ( is => 'ro', default => 'Forecast' );
has access              => ( is => 'ro', default => 0 );
has description         => ( is => 'ro', default => 'Weather forecasting.' );
has pattern             => ( is => 'ro', default => '^forecast ?' );
has function            => ( is => 'ro', default => sub { \&forecast } );
has usage               => ( is => 'ro', default => "Usage: !forecast" );
has timer_seconds       => ( is => 'ro', default => 3600 );

has timer_sub => ( is => 'ro', default => sub 
    { 
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->forecast; } ) 
    }
);

has on_message => ( is => 'ro', default =>
    sub {
        my $self = shift;
        $self->discord->gw->on('INTERACTION_CREATE' =>     
            sub {
                my ($gw, $msg) = @_;

                my $id    = $msg->{'id'};
                my $token = $msg->{'token'};
                my $data  = $msg->{'data'};

                if ($data->{'custom_id'} eq 'update.weather') {
                    $self->discord->interaction_response($id, $token, { type => 6 }, sub { $self->forecast });
                }    
            }
        )
    }
);

sub forecast {
    my ($self, $msg) = @_;
    my $config = $self->{'bot'}{'config'}{'forecast'};
    my $currentTemp = $config->{'current'};

    my %forecast = map {
        my ($name, $channel, $url) = split /,/, $config->{$_}, 3;
        $_ => {
            'name'    => $name,
            'channel' => $channel,
            'url'     => $url,
        }
    } grep { $_ ne 'current' } keys %$config;

    %forecast = currentTemp($currentTemp, %forecast);

    for my $city (sort keys %forecast) {
        cmd_forecast($self, $city, $forecast{$city});
    }

    if (defined $msg and exists $msg->{'channel_id'} and exists $msg->{'id'}) {
        $self->discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");
    }
}

sub currentTemp {
    my ($currentTemp, %forecast) = @_;
    
    my $res  = LWP::UserAgent->new->get($currentTemp);
    my $xml  = XMLin($res->content);
    
    my @items = @{ $xml->{observations}{station} };

    for my $item (@items) {
        for my $city (keys %forecast) {
            if (exists $item->{'description'} and $item->{'description'} eq $forecast{$city}{'name'}) {
                $forecast{$city}{'temp'} = $item->{period}{level}{element}[0]{content};
            }
        }
    }

    return %forecast;
}

sub cmd_forecast {
    my ($self, $city, $forecast) = @_;
    my $discord = $self->discord;
    my $config  = $self->{'bot'}{'config'}{'forecast'};
    my $db      = $self->db;

    my $res = LWP::UserAgent->new->get($forecast->{'url'});
    my $xml = XMLin($res->content);

    my (@forecasts, @conditions);
    if (exists $xml->{forecast}{area}[2]{'forecast-period'}) {
        @forecasts  = @{ $xml->{forecast}{area}[2]{'forecast-period'} };
        @conditions = @{ $xml->{forecast}{area}[1]{'forecast-period'} };
    } else {
        @forecasts = @{ $xml->{forecast}{area}[1]{'forecast-period'} };
    }

    my (@msg, $desc);
    my $i = 0;
    for my $day (@forecasts) {
        my $description_source = @conditions ? $conditions[$i] : $day;
        my $text_field = $description_source->{text};
        my $text_items_ref = (ref $text_field eq 'ARRAY') ? $text_field : [$text_field];
        $desc = "";
        if (@$text_items_ref && exists $text_items_ref->[0]{content}) {
            $desc = $text_items_ref->[0]{content};
        }
        my $date = str2time ($day->{'start-time-local'});
        push @msg, (sprintf "**%s**:", strftime "%a, %-d %B", localtime $date);
        
        my %minMax;
        if (ref $day->{element} eq 'ARRAY') {
            for my $d (@{ $day->{element} }) {
                if ($d->{'type'} eq 'air_temperature_minimum') {
                    $minMax{1} = "Min **$d->{'content'}**°C";
                } elsif ($d->{'type'} eq 'air_temperature_maximum') {
                    $minMax{2} = "Max **$d->{'content'}**°C";
                } elsif ($d->{'type'} eq 'precipitation_range') {
                    $minMax{3} = "Rain $d->{'content'}";
                    $minMax{3} =~ s/(\d+)/**$1**/g;
                }
            }
            push @msg, join '  /  ', map { $minMax{$_} } sort keys %minMax;
        }

        my $icon = "";
        if (ref $day->{element} eq 'ARRAY') {
            $icon = $day->{element}[0]{content};
        } elsif (ref $day->{element} eq 'HASH' && $day->{element}{type} eq 'forecast_icon_code') {
            $icon = $day->{element}{content};
        }
        push @msg, (sprintf "%s %s\n",  icon($icon), $desc);
        ++$i;
    }

    push @msg, sprintf "Last updated: **%s**.\nUpdating every: **%s** minutes.", strftime("%a %b %d %H:%M:%S %Y", localtime), 3600 / 60;
    my $content = "Current temp in **$city** is: **$forecast->{'temp'}**°C\n\n" . join ("\n", @msg);
    $content = substr( $content, 0, 2000 );

    my $forecast_messages = $db->get('forecast_messages') || {};
    my $existing_message_id = $forecast_messages->{$city};

    my $payload = {
        'content'    => $content,
        'components' => [
            {
                'type' => 1,
                'components' => [
                    {
                        'style'     => 1,
                        'label'     => 'UPDATE NOW',
                        'custom_id' => 'update.weather',
                        'disabled'  => 'false',
                        'type'      => 2
                    },
                ]
            }
        ],
    };

    if ($existing_message_id) {
        $discord->edit_message($forecast->{'channel'}, $existing_message_id, $payload, sub {
            my $response = shift;
            if (ref $response eq 'HASH' && $response->{code}) {
                $discord->send_message($forecast->{'channel'}, $payload, sub {
                    my $sent_msg = shift;
                    return unless ref $sent_msg eq 'HASH' && $sent_msg->{id};
                    $forecast_messages->{$city} = $sent_msg->{id};
                    $db->set('forecast_messages', $forecast_messages);
                });
            }
        });
    } else {
        $discord->send_message($forecast->{'channel'}, $payload, sub {
            my $sent_msg = shift;
            return unless ref $sent_msg eq 'HASH' && $sent_msg->{id};
            $forecast_messages->{$city} = $sent_msg->{id};
            $db->set('forecast_messages', $forecast_messages);
        });
    }
}

sub icon {
    my $code = shift;
    my %codes = (
        1  => 'sun_with_face',
        3  => 'partly_sunny',
        4  => 'cloud',
        11 => 'white_sun_rain_cloud',
        12 => 'cloud_rain',
        16 => 'thunder_cloud_rain',
        17 => 'white_sun_rain_cloud',
        18 => 'cloud_rain',
    );
    return exists $codes{$code} ? ":$codes{$code}:" : ":SHRUGGERS:";
}

1;