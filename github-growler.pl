#!/usr/bin/perl
use strict;
use warnings;
use 5.008001;
use App::Cache;
use Encode;
use Mac::Growl;
use File::Copy;
use LWP::Simple;
use URI;
use XML::Feed;

$XML::Atom::ForceUnicode = 1;

my %events = (
    "New Commits" => qr/(?:pushed to|committed to)/,
    "New Repository" => qr/created repository/,
    "Forked Repository" => qr/forked (?!gist:)/,
    "New Branch" => qr/created branch/,
    "New Gist" => qr/created gist:/,
    "Updated Gist" => qr/updated gist:/,
    "Forked Gist" => qr/forked gist:/,
    "Watching Project" => qr/started watching/,
    "Following People" => qr/started following/,
);

my $AppDomain = "net.bulknews.GitHubGrowler";

my $AppName = "Github Growler";
my @events  = ((keys %events), "Misc");
Mac::Growl::RegisterNotifications($AppName, [ @events, 'Error' ], \@events);

my $TempDir = "$ENV{HOME}/Library/Caches/$AppDomain";
mkdir $TempDir, 0777 unless -e $TempDir;

my $AppIcon = "$TempDir/octocat.png";
copy "octocat.png", $AppIcon;

my $Cache = App::Cache->new({ ttl => 60*60*24, application => $AppName });
my %Seen;

my %options = (interval => 300, maxGrowls => 10);
get_preferences(\%options, "interval", "maxGrowls");
my @args = @ARGV == 2 ? @ARGV : get_github_token();

while (1) {
    growl_feed(@args);
    sleep $options{interval};
}

sub get_preferences {
    my($opts, @keys) = @_;

    for my $key (@keys) {
        my $value = read_preference($key);
        $opts->{$key} = $value if defined $value;
    }
}

sub read_preference {
    my $key = shift;

    no warnings 'once';
    open OLDERR, ">&STDERR";
    open STDERR, ">/dev/null";
    my $value = `defaults read $AppDomain $key`;
    open STDERR, ">&OLDERR";

    return if $value eq '';
    chomp $value;
    return $value;
}

sub get_github_token {
    chomp(my $user  = `git config github.user`);
    chomp(my $token = `git config github.token`);

    unless ($user && $token) {
        die "Can't find .gitconfig entries for github.user and github.token\n";
    }

    return ($user, $token);
}

sub growl_feed {
    my($user, $token) = @_;

    my @feeds = (
        "http://github.com/$user.private.atom?token=$token",
        "http://github.com/$user.private.actor.atom?token=$token",
    );

    for my $uri (@feeds) {
        my $feed = eval { XML::Feed->parse(URI->new($uri)) };
        unless ($feed) {
            Mac::Growl::PostNotification($AppName, "Error", $AppName, "Can't parse the feed $uri", 0, 0, $AppIcon);
            next;
        }

        my @to_growl;
        for my $entry ($feed->entries) {
            next if $Seen{$entry->id}++;
            my $user = get_user($entry->author);
            $user->{name} ||= $entry->author;
            push @to_growl, { entry => $entry, user => $user };
        }

        my $i;
        for my $stuff (@to_growl) {
            my($event, $title, $description, $icon, $last);
            if ($i++ >= $options{maxGrowls}) {
                my %uniq;
                $event = "Misc";
                $title = (@to_growl - $options{maxGrowls}) . " more updates";
                my @who = grep !$uniq{$_}++, map $_->{user}{name}, @to_growl[$i..$#to_growl];
                $description = "From ";
                if (@who > 1) {
                    $description .= join ", ", @who[0..$#who-1];
                    $description .= " and " . $who[-1];
                } else {
                    $description .= "$who[0]";
                }
                $icon = $AppIcon;
                $last = 1;
            } else {
                my $body = munge_update_body($stuff->{entry}->content->body);
                $event = get_event_type($stuff->{entry}->title);
                $title = $stuff->{user}{name};
                $description  = $stuff->{entry}->title;
                $description .= ": $body" if $body;
                $icon = $stuff->{user}{avatar} ? "$stuff->{user}{avatar}" : $AppIcon;
            }
            Mac::Growl::PostNotification($AppName, $event, encode_utf8($title), encode_utf8($description), 0, 0, $icon);
            last if $last;
        }
    }
}

sub munge_update_body {
    use Web::Scraper;
    my $content = shift;
    my $res = scraper { process "div.message", message => 'TEXT' }->scrape($content);
    $res->{message} =~ s/^\s*[0-9a-f]{40}\s*//; # strip SHA1
    return $res->{message};
}

sub get_event_type {
    my $title = shift;

    for my $type (keys %events) {
        my $re = $events{$type};
        return $type if $title =~ $re;
    }

    return "Misc";
}

sub get_user {
    my $name = shift;
    $Cache->get_code("user:$name", sub {
        use Web::Scraper;
        my $scraper = scraper {
            process "#profile_name", name => 'TEXT';
            process ".identity img", avatar => [ '@src', sub {
                my $path = "$TempDir/$name.jpg";
                LWP::Simple::mirror($_, $path);
                return $path;
            } ];
        };

        return eval { $scraper->scrape(URI->new("http://github.com/$name")) } || {};
    });
}

__END__

=head1 NAME

github-growler

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 LICENSE

This program is licensed under the same terms as Perl itself.

=cut
