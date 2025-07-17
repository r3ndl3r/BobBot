package Command::OpenWeatherMap;
use feature 'say';
use utf8;

use Moo;
use strictures 2;
use namespace::clean;

use LWP::UserAgent;
use JSON::MaybeXS;
use URI::Escape;
use POSIX qw(strftime);

use Exporter qw(import);

has bot                 => ( is => 'ro' );
has discord             => ( is => 'lazy', builder => sub { shift->bot->discord } );
has log                 => ( is => 'lazy', builder => sub { shift->bot->log } );
has db                  => ( is => 'ro', required => 1 );
has name                => ( is => 'ro', default => 'OpenWeatherMap' );
has access              => ( is => 'ro', default => 1 );
has timer_seconds       => ( is => 'ro', default => 3600 );
has description         => ( is => 'ro', default => 'Weather forecasting via OpenWeatherMap.' );
has pattern             => ( is => 'ro', default => '^weather ?' );
has function            => ( is => 'ro', default => sub { \&cmd_weather_router } );
has usage               => ( is => 'ro', default => <<~'EOF'
    **Weather Command Help**

    `!weather add "City, CC" <channel_id1,channel_id2,...>`
    Adds a new forecast location to one or more channels.
    *Example:* `!weather add "Melbourne, AU" 968413731098886175,968413731098886176`

    `!weather edit <name> <channel_id1,channel_id2,...>`
    Updates the channels for an existing forecast location.
    *Example:* `!weather edit Melbourne 968413731098886175`

    `!weather remove <name>`
    Removes a forecast location from the database.
    *Example:* `!weather remove Melbourne`

    `!weather list`
    Displays all currently stored forecast locations.

    `!weather update`
    Manually triggers an immediate update for all forecasts.
    EOF
);


has timer_sub => ( is => 'ro', default => sub {
        my $self = shift;
        Mojo::IOLoop->recurring( $self->timer_seconds => sub { $self->run_all_forecasts; } )
    }
);


has on_message => ( is => 'ro', default => sub {
        my $self = shift;
        $self->discord->gw->on('INTERACTION_CREATE' => sub {
            my ($gw, $msg) = @_;
            return unless (ref $msg->{data} eq 'HASH' && $msg->{data}{custom_id});

            if ($msg->{data}{custom_id} eq 'update.weather') {
                $self->debug("'UPDATE NOW' button clicked by user " . $msg->{member}{user}{username});
                # Acknowledge the click immediately and then run the update.
                $self->discord->interaction_response($msg->{id}, $msg->{token}, { type => 6 }, sub {
                    $self->run_all_forecasts();
                });
            }
        })
    }
);


sub cmd_weather_router {
    my ($self, $msg) = @_;
    $self->debug("cmd_weather_router triggered by user " . $msg->{author}{username});
    my $args_str = $msg->{'content'};
    $args_str =~ s/^weather\s*//i;

    my $command_processed = 0;

    if ($args_str =~ /^add\s+"([^"]+)"\s+([\d,]+)/i) {
        my @channel_ids = split /,/, $2;
        $self->debug("Routing to 'add_forecast' with city:'$1' and channels:'@channel_ids'");
        $self->add_forecast($msg, $1, \@channel_ids);
        $command_processed = 1;
    } elsif ($args_str =~ /^edit\s+([^\s]+)\s+([\d,]+)/i) {
        my @channel_ids = split /,/, $2;
        $self->debug("Routing to 'edit_forecast' for city:'$1' with new channels:'@channel_ids'");
        $self->edit_forecast($msg, $1, \@channel_ids);
        $command_processed = 1;
    } elsif ($args_str =~ /^remove\s+(.+)/i) {
        $self->debug("Routing to 'remove_forecast' for city:'$1'");
        $self->remove_forecast($msg, $1);
        $command_processed = 1;
    } elsif ($args_str =~ /^list/i) {
        $self->debug("Routing to 'list_forecasts'");
        $self->list_forecasts($msg);
        $command_processed = 1;
    } elsif ($args_str =~ /^update/i) {
        $self->debug("Routing to 'run_all_forecasts' for manual update.");
        $self->discord->send_message($msg->{channel_id}, "Manually updating all forecasts...");
        $self->run_all_forecasts($msg);
        $command_processed = 1;
    } else {
        $self->debug("No valid subcommand found. Displaying usage.");
        $self->discord->send_message($msg->{channel_id}, $self->usage);
        $self->bot->react_error($msg->{channel_id}, $msg->{id});
    }

    if ($command_processed) {
        $self->bot->react_robot($msg->{channel_id}, $msg->{id});
    }
}


sub run_all_forecasts {
    my ($self, $msg) = @_;
    $self->debug("run_all_forecasts started.");
    my $forecasts = $self->db->get('weather') || {};
   $self->debug("Found " . scalar(keys %$forecasts) . " cities to update.");

    for my $city (keys %$forecasts) {
        $self->update_city_forecast($city, $forecasts->{$city});
    }

    if (defined $msg and exists $msg->{'id'}) {
        $self->bot->react_robot($msg->{'channel_id'}, $msg->{'id'});
    }
    $self->debug("run_all_forecasts finished.");
}

# Fetches and posts the forecast for a single city.
sub update_city_forecast {
    my ($self, $city, $city_data) = @_;
    $self->debug("Updating forecast for '$city'.");
    my $apikey = $self->bot->config->{openweathermap}{apikey};

    unless ($apikey) {
        $self->debug("API key is not configured in config.ini");
        return;
    }

    my $ua = LWP::UserAgent->new;
    my $onecall_url = "https://api.openweathermap.org/data/3.0/onecall?lat=$city_data->{lat}&lon=$city_data->{lon}&exclude=minutely,hourly,alerts&units=metric&appid=$apikey";
    $self->debug("Fetching URL: $onecall_url");

    my $res = $ua->get($onecall_url);

    unless ($res->is_success) {
        $self->debug("Failed to fetch weather for $city: " . $res->status_line . ". Response: " . $res->decoded_content);
        return;
    }

    my $weather_data = decode_json($res->decoded_content);
    my $payload = $self->format_weather_embed($city, $weather_data);

    my $channels_ref = ref $city_data->{channels} eq 'ARRAY' ? $city_data->{channels} : [];
    $self->debug("Found " . scalar(@$channels_ref) . " channels for '$city'.");

    for my $channel_id (@$channels_ref) {
        my $message_id = $city_data->{message_ids}{$channel_id};
        if ($message_id) {
            $self->debug("Editing existing message '$message_id' in channel '$channel_id' for '$city'.");
            $self->discord->edit_message($channel_id, $message_id, $payload, sub {
                my $response = shift;
                if (defined $response->{code} && $response->{code} == 10008) { # Unknown Message
                    $self->debug("Message '$message_id' not found in channel '$channel_id'. Sending a new one.");
                    $self->send_and_save_forecast($city, $channel_id, $payload);
                }
            });
        } else {
            $self->debug("No existing message for '$city' in channel '$channel_id'. Sending a new one.");
            $self->send_and_save_forecast($city, $channel_id, $payload);
        }
    }
}


sub get_weather_emoji {
    my ($self, $icon_code) = @_;
    my %icon_map = (
        '01d' => '☀️', '01n' => '🌙', '02d' => '🌤️', '02n' => '☁️',
        '03d' => '☁️', '03n' => '☁️', '04d' => '🌥️', '04n' => '🌥️',
        '09d' => '🌦️', '09n' => '🌧️', '10d' => '🌧️', '10n' => '🌧️',
        '11d' => '⛈️', '11n' => '⛈️', '13d' => '❄️', '13n' => '❄️',
        '50d' => '🌫️', '50n' => '🌫️',
    );
    return $icon_map{$icon_code} || '❔';
}

# Builds the final Discord embed message from the API data.
sub format_weather_embed {
    my ($self, $city_name, $data) = @_;
    $self->debug("Formatting embed for '$city_name'.");

    my $current = $data->{current};
    my $current_temp = sprintf "%.1f", $current->{temp};
    my $feels_like = sprintf "%.1f", $current->{feels_like};
    my $description = ucfirst($current->{weather}[0]{description});
    my $icon = $current->{weather}[0]{icon};
    my $icon_url = "https://openweathermap.org/img/wn/$icon\@2x.png";
    my $current_emoji = $self->get_weather_emoji($icon);
    
    my $wind_speed_kmh = sprintf "%.1f", $current->{wind_speed} * 3.6;
    my $sunrise = strftime "%I:%M %p", localtime($current->{sunrise});
    my $sunset = strftime "%I:%M %p", localtime($current->{sunset});
    my $today_pop_percent = (exists $data->{daily}[0]{pop}) ? int($data->{daily}[0]{pop} * 100) : 0;
    
    my $current_details = "Feels like $feels_like°C\nHumidity: $current->{humidity}%\nWind: ${wind_speed_kmh} km/h\nSunrise: $sunrise\nSunset: $sunset";
    
    if ($today_pop_percent > 0) {
        $current_details .= "\nChance of Rain: **$today_pop_percent%**.";
    }

    my $location_local_time = strftime("%a %b %d %I:%M:%S %p %Y", gmtime($current->{dt} + $data->{timezone_offset}));

    my $embed = {
        author => { name => "Weather for $city_name", icon_url => $icon_url },
        title => "$current_emoji $description, $current_temp°C",
        description => $current_details,
        color => 0x3498DB,
        fields => [],
        footer => { 
            text => sprintf("Last updated: %s\nLocal time of %s: %s\nUpdating every: %s minutes.", 
                            strftime("%a %b %d %I:%M:%S %p %Y", localtime), 
                            $city_name, # Changed from "location" to $city_name
                            $location_local_time,
                            $self->timer_seconds / 60)
        }
    };

    my @daily = @{$data->{daily}};
    shift @daily; 

    my $forecast_string = "";
    for my $day (@daily[0..5]) {
        my $day_name = strftime "**%A**:", localtime($day->{dt});
        my $min_temp = sprintf "%.0f", $day->{temp}{min};
        my $max_temp = sprintf "%.0f", $day->{temp}{max};
        my $day_desc = ucfirst($day->{weather}[0]{description});
        my $emoji = $self->get_weather_emoji($day->{weather}[0]{icon});
        my $day_pop_percent = int($day->{pop} * 100);
        my $rain_info = $day_pop_percent > 0 ? " (☔ *${day_pop_percent}%*)" : "";
        
        my $day_wind_speed_kmh = sprintf "%.0f", $day->{wind_speed} * 3.6;
        my $wind_info = "";
        if ($day_wind_speed_kmh > 30) {
            $wind_info = "🌬️ **${day_wind_speed_kmh} km/h**";
            if (exists $day->{wind_gust}) {
                my $day_wind_gust_kmh = sprintf "%.0f", $day->{wind_gust} * 3.6;
                $wind_info .= " (Gusts **${day_wind_gust_kmh} km/h**)";
            }
        }
        
        $forecast_string .= "$day_name $emoji $day_desc. Max: **${max_temp}°C**, Min: **${min_temp}°C**.$rain_info";
        $forecast_string .= "\n$wind_info" if $wind_info;
        $forecast_string .= "\n\n";
    }
    
    push @{$embed->{fields}}, { name => "Forecast", value => $forecast_string, inline => \0 };

    return { embeds => [$embed], components => [{ type => 1, components => [{'style' => 1, 'label' => 'UPDATE NOW', 'custom_id' => 'update.weather', 'disabled' => 'false', 'type' => 2 }]}]};
}


sub add_forecast {
    my ($self, $msg, $city_query, $channel_ids_ref) = @_;
    $self->debug("Executing 'add_forecast' for city '$city_query'.");
    my $apikey = $self->bot->config->{openweathermap}{apikey};

    unless ($apikey) {
        $self->debug("API key is missing from config.ini");
        $self->discord->send_message($msg->{channel_id}, "Error: OpenWeatherMap API key is not configured.");
        $self->bot->react_error($msg->{channel_id}, $msg->{id});
        return;
    }

    my $ua = LWP::UserAgent->new;
    my $geo_url = "http://api.openweathermap.org/geo/1.0/direct?q=" . uri_escape($city_query) . "&limit=1&appid=$apikey";
    my $res = $ua->get($geo_url);

    unless ($res->is_success) {
        $self->debug("Geocoding API failed for '$city_query': " . $res->status_line);
        $self->discord->send_message($msg->{channel_id}, "Error: Could not contact the location API.");
        $self->bot->react_error($msg->{channel_id}, $msg->{id});
        return;
    }

    my $locations = eval { decode_json($res->decoded_content) };
    if ($@ || !@$locations) {
        $self->debug("Geocoding failed for '$city_query': No locations found or bad JSON.");
        $self->discord->send_message($msg->{channel_id}, "Location '$city_query' not found.");
        $self->bot->react_error($msg->{channel_id}, $msg->{id});
        return;
    }

    my $loc = $locations->[0];
    my $city_name = $loc->{name};
    my $forecasts = $self->db->get('weather') || {};
    
    $forecasts->{$city_name} = {
        lat         => $loc->{lat},
        lon         => $loc->{lon},
        channels    => $channel_ids_ref,
        message_ids => {},
    };
    
    $self->db->set('weather', $forecasts);
    $self->debug("Saved new forecast for '$city_name' to DB.");
    $self->discord->send_message($msg->{channel_id}, "Added forecast for **$city_name** to " . scalar(@$channel_ids_ref) . " channel(s).");
    $self->update_city_forecast($city_name, $forecasts->{$city_name});
}


sub edit_forecast {
    my ($self, $msg, $name, $channel_ids_ref) = @_;
    $self->debug("Executing 'edit_forecast' for city '$name'.");
    my $forecasts = $self->db->get('weather') || {};

    if (my $city_data = $forecasts->{$name}) {
        my $old_channels_ref = ref $city_data->{channels} eq 'ARRAY' ? $city_data->{channels} : [];
        my $old_message_ids_ref = ref $city_data->{message_ids} eq 'HASH' ? $city_data->{message_ids} : {};

        $self->debug("Deleting old messages for '$name'.");
        for my $channel_id (@$old_channels_ref) {
            if (my $message_id = $old_message_ids_ref->{$channel_id}) {
                $self->discord->delete_message($channel_id, $message_id);
            }
        }

        $city_data->{channels} = $channel_ids_ref;
        $city_data->{message_ids} = {};
        
        $self->db->set('weather', $forecasts);
        $self->debug("Updated channels for '$name' in DB.");
        $self->discord->send_message($msg->{channel_id}, "Updated channels for **$name**. Triggering new forecast...");
        $self->update_city_forecast($name, $city_data);
    } else {
        $self->debug("City '$name' not found for editing.");
        $self->discord->send_message($msg->{channel_id}, "Forecast for **$name** not found.");
        $self->bot->react_error($msg->{channel_id}, $msg->{id});
    }
}


sub remove_forecast {
    my ($self, $msg, $name) = @_;
    $self->debug("Executing 'remove_forecast' for city '$name'.");
    my $forecasts = $self->db->get('weather') || {};

    if (my $city_data = $forecasts->{$name}) {
        my $channels_ref = ref $city_data->{channels} eq 'ARRAY' ? $city_data->{channels} : [];
        my $message_ids_ref = ref $city_data->{message_ids} eq 'HASH' ? $city_data->{message_ids} : {};

        $self->debug("Deleting messages for '$name' before removal.");
        for my $channel_id (@$channels_ref) {
            if (my $message_id = $message_ids_ref->{$channel_id}) {
                $self->discord->delete_message($channel_id, $message_id);
            }
        }
        delete $forecasts->{$name};
        $self->db->set('weather', $forecasts);
        $self->debug("Removed '$name' from DB.");
        $self->discord->send_message($msg->{channel_id}, "Removed forecast for **$name**.");
    } else {
        $self->debug("City '$name' not found for removal.");
        $self->discord->send_message($msg->{channel_id}, "Forecast for **$name** not found.");
        $self->bot->react_error($msg->{channel_id}, $msg->{id});
    }
}


sub list_forecasts {
    my ($self, $msg) = @_;
    $self->debug("Executing 'list_forecasts'.");
    my $forecasts = $self->db->get('weather') || {};

    if (keys %$forecasts) {
        my $message = "Stored forecasts:\n";
        for my $name (sort keys %$forecasts) {
            my $forecast = $forecasts->{$name};
            my $channels_ref = ref $forecast->{channels} eq 'ARRAY' ? $forecast->{channels} : [];
            my $channels_str = join(', ', @$channels_ref);
            $message .= "**$name**: Channels: `$channels_str`\n";
        }
        $self->discord->send_message($msg->{channel_id}, $message);
    } else {
        $self->discord->send_message($msg->{channel_id}, "No forecasts are currently stored.");
        $self->bot->react_error($msg->{channel_id}, $msg->{id});
    }
}


sub send_and_save_forecast {
    my ($self, $city, $channel_id, $payload) = @_;
    $self->debug("Sending new forecast message for '$city' to channel '$channel_id'.");
    $self->discord->send_message($channel_id, $payload, sub {
        my $sent_msg = shift;
        if (ref $sent_msg eq 'HASH' && $sent_msg->{id}) {
            my $forecasts = $self->db->get('weather') || {};
            if (exists $forecasts->{$city}) {
                $forecasts->{$city}{message_ids} //= {};
                $forecasts->{$city}{message_ids}{$channel_id} = $sent_msg->{id};
                $self->db->set('weather', $forecasts);
                $self->debug("Saved new message ID '" . $sent_msg->{id} . "' for '$city' in channel '$channel_id'.");
            }
        }
    });
}

1;