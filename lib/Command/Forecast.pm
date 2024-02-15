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
use POSIX qw(strftime);

use Exporter qw(import);
our @EXPORT_OK = qw(cmd_forecast);

my $currentTemp = 'ftp://ftp.bom.gov.au/anon/gen/fwo/IDV60920.xml';

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );

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
                    $self->discord->interaction_response($id, $token, $data->{'custom_id'}, 'UPDATING PLEASE WAIT...', sub { $self->forecast });
                }    
            }
        )
    }
);


sub forecast {
    my ($self, $msg) = @_;

    my %forecast = (
        'melbourne' => {
            'name'    => 'Melbourne (Olympic Park)',
            'channel' => '968413731098886175',
            'url'     => 'ftp://ftp.bom.gov.au/anon/gen/fwo/IDV10450.xml',
        },

        'bendigo'     => {
            'name'    => 'Bendigo',
            'channel' => '969160853825921044',
            'url'     => 'ftp://ftp.bom.gov.au/anon/gen/fwo/IDV10706.xml',
        },
    );

    %forecast = currentTemp(%forecast);

    for my $city (sort keys %forecast) {
        cmd_forecast($self, $city, $forecast{$city});
    }

    $self->discord->create_reaction($msg->{'channel_id'}, $msg->{'id'}, "🤖");

    # Clean up old forecast messages
    $self->cleanup_forecast_messages();
}

sub currentTemp {
    my %forecast = @_;
    
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

    # Weekly forecast.
    my $res = LWP::UserAgent->new->get($forecast->{'url'});
    my $xml = XMLin($res->content);

    my (@forecasts, @conditions);

    if ($city eq 'melbourne') {

        @forecasts  = @{ $xml->{forecast}{area}[2]{'forecast-period'} };
        @conditions = @{ $xml->{forecast}{area}[1]{'forecast-period'} };

    } elsif ($city eq 'bendigo') {

        @forecasts = @{ $xml->{forecast}{area}[1]{'forecast-period'} };
    }

    my (@msg, $desc);
    my $i = 0;
    for my $day (@forecasts) {

        
        if ($city eq 'melbourne') {
            if (ref $conditions[$i]{text} eq 'HASH') {
                $desc = $conditions[$i]{text}{content};
            } else {
                $desc = $conditions[$i]{text}[0]{content};
            }
        } elsif ($city eq 'bendigo') {
            $desc = $day->{text}[0]{content}; 
        }

        my $date = str2time ($day->{'start-time-local'});

        push @msg, (sprintf "**%s**:", strftime "%a, %-d %B", localtime $date);
        
        # Populate %minMax with min/max temps and precipitation information. Order using 1-3 hash keys.
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

            # Join all the info together.
            push @msg, join '  /  ', map { $minMax{$_} } sort keys %minMax;

        }

        # Sometimes we're not getting weather / temp? (WHY?!?!?)
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

    $discord->send_message($forecast->{'channel'}, 
        {
            'content' => $content,
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
        },
        sub {
            my $id  = shift->{'id'};
            my $db  = Component::DBI->new();

            if (defined $db->get("forecast-$city")) {
                my $old = ${ $db->get("forecast-$city") };
            
                $discord->delete_message($forecast->{'channel'}, $old) if $old && $old =~ /^\d+$/;
            }

            $db->set("forecast-$city", \$id);
        }
    );
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

sub cleanup_forecast_messages {
    my $self = shift;
    my $discord = $self->discord;
    my %forecast = (
        'melbourne' => '968413731098886175',
        'bendigo'   => '969160853825921044',
    );

    for my $city (keys %forecast) {
        my $db = Component::DBI->new();
        my $message_ids = $db->get("forecast-$city");

        # Delete all messages except the most recent one
        my @sorted_ids = sort { $b <=> $a } grep { /^\d+$/ } @{$message_ids};
        for my $id (@sorted_ids[1..$#sorted_ids]) {
            $discord->delete_message($forecast{$city}, $id);
        }

        # Update database to keep only the most recent message
        $db->set("forecast-$city", [ $sorted_ids[0] ]);
    }
}

1;
