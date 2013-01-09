#!/usr/bin/perl

use Modern::Perl;
use Net::HTTP::Spore;
use Data::Dumper;

my $bugz = `which bugz`;
chomp $bugz;
my $bugz_base = "http://bugs.koha-community.org/bugzilla3/";

my $client = Net::HTTP::Spore->new_from_spec('trello.json');
$client->enable('Format::JSON');

my $community_board_id = "4f1d247284210f0e6300d7d7";

my @lists = (
    { id => "4f1d25c8b42dab031c206c93", expected_status => "Needs Signoff" },
    { id => "4f1d25d0b42dab031c207016", expected_status => "Signed Off" },
    { id => "4f1d25ddb42dab031c2077b4", expected_status => "Passed QA" },
#    { id => "4f1d25e2b42dab031c2079cc", expected_status => "Pushed to (Master|Stable)" },
#    { id => "4f1d25eeb42dab031c20899e", expected_status => "RESOLVED" },
);

my @todo;

foreach my $list (@lists) {
    print "List $list->{id}\n";
    my $response = $client->get_lists_idlist_cards(
        key => $key,
        idList => $list->{id},
    );
    my $cards = $response->{body};
    foreach my $card (@$cards) {
        print "\tCard $card->{id}: $card->{name}\n";
        my ($bz) = ($card->{name} =~ /(\d+)/);
        my $bugz_output = `$bugz -b $bugz_base --skip-auth get -a -n $bz | grep Status`;
        my ($status) = ($bugz_output =~ /Status *: (.*)/);
        if ($status !~ /$list->{expected_status}/) {
            push @todo, "Move card '$card->{name}': status is $status";
        }
    }
}

print "TODO \n";
print join ("\n", @todo) . "\n";
