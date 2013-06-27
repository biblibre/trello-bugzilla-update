#!/usr/bin/perl

use Modern::Perl;
use Net::HTTP::Spore;
use Text::CSV;
use JSON;
use Pod::Usage;
use FindBin qw( $Bin );
use Getopt::Long;
use Data::Dumper;

BEGIN {
    eval "require Net::HTTP::Spore";
    die "Net::HTTP::Spore is not installed\nrun:\ncpan install Net::HTTP::Spore\nto install it\n" if $@;
    eval "require Text::CSV";
    die "Net::HTTP::Spore is not installed\nrun:\naptitude install libtext-csv-perl\nto install it\n" if $@;
};


# Configuration variables
my $bugz_urlbase = "http://bugs.koha-community.org/bugzilla3/";
my $trello_json_spec_filepath = $Bin . q{/trello.json};

my $trello_board_id = q{4f1d247284210f0e6300d7d7};
my $trello_api_secret_key = q{};
my $trello_api_token = q{};

my $gdoc_csv_filename = $Bin . q{/gdoc.csv};
my $gdoc_spreadsheet = q{https://docs.google.com/a/biblibre.com/spreadsheet/ccc?key=0AuZF5Y_c4pIxdHE3S0RXMjJqSzZ3d1BVUmxpRnRVUUE#gid=3};


my $developments_from = 2011; # We want developments made after 2010 (2011 is included).

my $gdoc_module_cn = 7; # Column number in the gdoc for module name
my $gdoc_mt_number_cn = 12; # Column number in the gdoc for mt number
my $gdoc_bz_number_cn = 13; # Column number in the gdoc for bz number
my $gdoc_bz_status_cn = 14; # Column number in the gdoc for bz status
my $gdoc_year_cn = 3; # Column number in the gdoc for the development year

# Trello => BZ
my $status_mapping_trello_bz = {
    "New"               => ["NEW"],
    "To start"          => ["ASSIGNED"],
    "In progress"       => ["ASSIGNED"],
    "Needs sign off"    => ["Needs Signoff"],
    "Needs QA"          => ["Signed Off"],
    "Passed QA"         => ["Passed QA"],
    "Patch pushed"      => ["Pushed to Master", "Pushed to Stable"],
    "Resolved-fixed"    => ["RESOLVED", "CLOSED"],
};
# BZ => Trello
my $status_mapping_bz_trello = {
    "NEW"                   => "New",
    "In Discussion"         => "In discussion or blocked",
    "ASSIGNED"              => "To start",
    "Patch doesn't apply"   => "To start",
    "Needs Signoff"         => "Needs sign off",
    "Signed Off"            => "Needs QA",
    "Passed QA"             => "Passed QA",
    "Failed QA"             => "To start",
    "Pushed to Master"      => "Patch pushed",
    "Pushed to Stable"      => "Pushed to stable",
    "RESOLVED"              => "Resolved-fixed",
    "CLOSED"                => "Resolved-fixed",
};
my @done_status = ( "RESOLVED", "CLOSED", "Pushed to Master", "Pushed to Stable" );
my @in_progress_status = ( "New", "ASSIGNED", 'In Discussion', "Patch doesn't apply", "Needs Signoff", "Signed Off", "Passed QA", "Failed QA" );

my ( $help, $man, $verbose, $confirm, $unserialize );
GetOptions(
    'help|h'        => \$help,
    'man'           => \$man,
    'verbose|v'     => \$verbose,
    'confirm|c'     => \$confirm,
    'unserialize|u' => \$unserialize,
) or pod2usage(2);
pod2usage( -verbose => 2 ) if ($man);
pod2usage(1) if $help;

die "The trello board id is needed, please edit this script" unless $trello_board_id;
die "The trello api secret key is needed, please edit this script" unless $trello_api_secret_key;
die "The trello api token is needed, please edit this script" unless $trello_api_token;

my $json_cards_per_list = q{/tmp/cards_per_list.json};
my $json_bz_status = q{/tmp/bz_status.json};

if ( $unserialize ) {
    unless ( -f $json_cards_per_list and -f $json_bz_status ) {
        pod2usage( -msg => "You cannot unserialize if the script is launched for the first time" );
    }
}

$verbose = 1 unless $confirm;

my $bugz = `which bugz`;
chomp $bugz;
die "ERROR: bugz should be installed" unless $bugz;

my $client = Net::HTTP::Spore->new_from_spec($trello_json_spec_filepath);
$client->enable('Format::JSON');

my $response = $client->get_boards_board_id(
    key => $trello_api_secret_key,
    board_id => $trello_board_id,
    lists => 'all'
);
my $board = $response->{body};
my $lists = $board->{lists};



my $cards_per_list = {};
unless ( $unserialize ) {
    say "Getting cards list from Trello..." if $verbose;
    for my $list ( @$lists ) {
        say "List " . $list->{name} . " (" . $list->{id} . ")" if $verbose;
        $response = $client->get_lists_idlist(
            key => $trello_api_secret_key,
            idList => $list->{id},
            cards => 'all'
        );
        my $cards = $response->{body}{cards};
        for my $card ( @$cards ) {
            say "\t" . $card->{name} if $verbose;
            push @{ $cards_per_list->{ $list->{id} } }, $card;
        }
    }
    serialize( $cards_per_list, "/tmp/cards_per_list.json" );
} else {
    say "Getting cards list from the serialize file..." if $verbose;
    $cards_per_list = unserialize( $json_cards_per_list );
}

my $current_bz_status = {};
unless ( $unserialize ) {
    say "Getting status from bugzilla..." if $verbose;
    while ( my ( $id_list, $cards ) = each %$cards_per_list ) {
        my ( $list ) = grep { $_->{id} eq $id_list } @$lists;
        say "List $list->{name} ($list->{id})" if $verbose;
        foreach my $card ( @$cards ) {
            print "\tCard $card->{id}: $card->{name}\n";
            my ($bz_number) = ($card->{name} =~ /^(\d+)/);
            unless ( $bz_number ) {
                say "\t\tWARNING: Problem with this card, the bug number cannot be retrieve for the card name" if $verbose;
                next;
            }
            my $bugz_output = `$bugz -b $bugz_urlbase --skip-auth get -a -n $bz_number | grep Status`;
            my ($status) = ($bugz_output =~ /Status *: (.*)/);
            $current_bz_status->{$bz_number} = $status;
        }
    }
    serialize( $current_bz_status, '/tmp/bz_status.json' );
} else {
    say "Getting status from the serialize file..." if $verbose;
    $current_bz_status = unserialize( $json_bz_status );
}


say "Updating status on the trello board..." if $verbose;
while ( my ( $id_list, $cards ) = each %$cards_per_list ) {
    my ( $list ) = grep { $_->{id} eq $id_list } @$lists;

    next if $list->{name} eq "Resolved-fixed";
    my $expected_bz_status = $status_mapping_trello_bz->{$list->{name}};
    next unless defined $expected_bz_status; # Do not used others lists

    for my $card ( @$cards ) {
        my ( $bz_number ) = ( $card->{name} =~ /^(\d+)/ );
        next unless $bz_number;
        if ( $list->{name} ne $status_mapping_bz_trello->{$current_bz_status->{$bz_number}} ) {
            my ( $new_id_list ) = map { $_->{name} eq $status_mapping_bz_trello->{$current_bz_status->{$bz_number}} ? $_->{id} : ()} @$lists;
            say " * $bz_number ($current_bz_status->{$bz_number}) $list->{name}  => $status_mapping_bz_trello->{$current_bz_status->{$bz_number}} ($new_id_list)"
                if $verbose;
            if ( $confirm ) {
                $response = $client->put_cards_card_id_or_shortlink(
                    key => $trello_api_secret_key,
                    card_id_or_shortlink => $card->{id},
                    idList => $new_id_list,
                    pos => '65535',
                    token => $trello_api_token
                );
                if ( $response->{status} eq '200' ) {
                    say "Moved!" if $verbose;
                } else {
                    say "Move failed!" if $verbose;
                }
            }
        }
    }
}

say qq|Go on $gdoc_spreadsheet > File > Download as csv|;
say qq|And copy it into the same directory as this script under the name "$gdoc_csv_filename"|;
say q|Then press enter|;
while ( <> ) {
    last if -f $gdoc_csv_filename;
    say "I still not find the file $gdoc_csv_filename";
}

my @rows;
my $csv = Text::CSV->new ( { binary => 1 } )
    or die "Cannot use CSV: " . Text::CSV->error_diag ();


my ( @invalid_bz_numbers, @new_statuses, $total);
open my $fh, "<:encoding(utf8)", "$gdoc_csv_filename" or die "$gdoc_csv_filename: $!";
my @bz_number_on_trello;
for my $cards ( values %$cards_per_list ) {
    for my $card ( @$cards ) {
        my ( $bz_number ) = ( $card->{name} =~ /^(\d+)/ );
        push @bz_number_on_trello, $bz_number if $bz_number;
    }
}
while ( my $row = $csv->getline( $fh ) ) {
    next if $csv->record_number == 1; # skip the header
    next if $row->[$gdoc_year_cn] !~ /^\d*$/ or $row->[$gdoc_year_cn] < $developments_from;
    $total->{total}++;

    my $module = $row->[$gdoc_module_cn];
    my $mt_number = $row->[$gdoc_mt_number_cn];
    my $bz_number = $row->[$gdoc_bz_number_cn];
    my $bz_status = $row->[$gdoc_bz_status_cn];
    chomp $bz_status;
    my $line_number = $csv->record_number;
    $total->{by_module}{$module}{$bz_status}++;
    if ( $bz_status ~~ @done_status ) {
        $total->{by_module}{$module}{done}++;
        $total->{done}++;
    } else {
        $total->{by_module}{$module}{started}++;
        $total->{started}++;
    }
    if ( $bz_status ~~ @in_progress_status ) {
        $total->{by_module}{$module}{in_progress}++;
        $total->{in_progress}++;
    }
    unless ( $bz_number and $bz_number =~ /^\d*$/ ) {
        push @invalid_bz_numbers, {
            line_number => $csv->record_number,
            reason => qq{bz number "$bz_number" (MT$mt_number) is not a number},
        };
        $total->{certainly_new}++;
        next;
    }

    unless ( $bz_number ~~ @bz_number_on_trello ) {
        push @invalid_bz_numbers, {
            line_number => $line_number,
            reason => qq{card with bz number $bz_number (MT$mt_number) is not on the trello board},
        };
        next;
    }

    # Dont want to change status closed or resolved
    if ( not $bz_status ~~ [ qw( CLOSED RESOLVED ) ] ) {
        unless ( $current_bz_status->{$bz_number} =~ m|^$bz_status$|i ) {
            push @new_statuses, {
                line_number => $line_number,
                old => $bz_status,
                new => $current_bz_status->{$bz_number},
                bz_number => $bz_number,
            };
        }
    }
    if ( exists $current_bz_status->{$bz_number} ) {
        $total->{$current_bz_status->{$bz_number}}++;
    } else {
        $total->{CLOSED_OR_RESOLVED}++;
    }
}
close $fh;


# FIXME TODO Check if something is on the trello and not in the biblibre dev ?

say "===== REPORT =====";
say "=== Invalids (gdoc) ===";
for my $invalid ( @invalid_bz_numbers ) {
    say "\t$invalid->{reason} (l.$invalid->{line_number})";
}

say "=== Status changed ===";
if ( @new_statuses ) {
    for my $status ( @new_statuses ) {
        say "\t Bug $status->{bz_number} has changed from $status->{old} to $status->{new} (l.$status->{line_number})";
    }
} else {
    say "No status changed!";
}

say "=== Total ===";
say "$total->{total} lines match";
say "$total->{started} are started, $total->{done} are done and $total->{in_progress} are in progress";
my $acq_done = $total->{by_module}{Serials}{done} + $total->{by_module}{Acquisitions}{done};
my $others_done = $total->{done} - $acq_done;
say "Done: ACQ+SERIALS: $acq_done ; OTHERS: $others_done";

my $acq_started = $total->{by_module}{Serials}{started} + $total->{by_module}{Acquisitions}{started};
my $others_started = $total->{started} - $acq_started;
say "Started: ACQ+SERIALS: $acq_started ; OTHERS: $others_started";

my $acq_in_progress = $total->{by_module}{Serials}{in_progress} + $total->{by_module}{Acquisitions}{in_progress};
my $others_in_progress = $total->{in_progress} - $acq_in_progress;
say "In progress: ACQ+SERIALS: $acq_in_progress ; OTHERS: $others_in_progress";

sub serialize {
    my ( $struct, $filepath ) = @_;
    my $json;
    open my $fh, ">", $filepath;
    print $fh encode_json( $struct );
    close $fh;
}

sub unserialize {
    my ( $filepath ) = @_;
    open my $fh, "<", $filepath;
    my $json = <$fh>;
    close $fh;
    return decode_json( $json );
}

__END__

=head1 NAME

trello-update.pl

=head1 SYNOPSIS

trello-update.pl [--confirm] [--help] [--man] [--verbose] [--unserialize]


=head1 DESCRIPTION

trello-update.pl is a script for a specific need at BibLibre.
We use Trello and google-doc to follow our bug community workflow.
It is become difficult to maintain 2 things.

You have to fill the trello_api_secret_key and the $trello_api_token at the top of this script.
See https://trello.com/docs/gettingstarted/index.html#getting-an-application-key
and https://trello.com/docs/gettingstarted/#getting-a-token-from-a-user

There are 4 steps:

1/ Get a cards list of the trello board

2/ Get bug statuses from bugzilla

3/ Updating the statuses on the trello (only if --confirm is given)

4/ Check statuses from the gdoc. For this last step, you shall extract the gdoc as a csv file and place it at the right place.

=head1 OPTIONS

=over 8

=item B<-h|--help>

Print this help message

=item B<-m|--man>

Print the man.

=item B<-v|--verbose>

Set the verbosity flag.

=item B<-c|--confirm>

Without this flag, the trello board will not updated.

=item B<-u|--unserialize>

The first time this script is launched, the trello lists and bugs statuses should be get from the remote servers.
The script serialize informations into temporary files.
So next, you can call the script with the --unserialize options and it will use the files created to extract previous data.

=back

=head1 AUTHOR

Julian Maurice <julian.maurice@biblibre.com>

Jonathan Druart <jonathan.druart@biblibre.com>

=head1 COPYRIGHT

This software is Copyright (c) 2013 by BibLibre

=head1 LICENSE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 DISCLAIMER OF WARRANTY

This program comes with ABSOLUTELY NO WARRANTY; for details type `show w'.
This is free software, and you are welcome to redistribute it
under certain conditions; type `show c' for details.

=cut
